/*
    Copyright (C) 2015 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample’s licensing information
    
    Abstract:
    This class manages the main character, including its animations, sounds and direction.
*/

import SceneKit

private typealias ParticleEmitter = (node: SCNNode, particleSystem: SCNParticleSystem, birthRate: CGFloat)

class FoxCharacter {
    
    var replacementPosition : SCNVector3?
    var maxPenetrationDistance = CGFloat(0.0)
    
    // MARK: Initialization
    
    init() {
        
        // MARK: Load character from external file
        
        // The character is loaded from a .scn file and stored in an intermediate
        // node that will be used as a handle to manipulate the whole group at once
        
        let characterScene = SCNScene(named: "game.scnassets/fox.scn")!
        let characterTopLevelNode = characterScene.rootNode.childNodes[0]
        node.addChildNode(characterTopLevelNode)
        
        
        // MARK: Configure collision capsule
        
        // Collisions are handled by the physics engine. The character is approximated by
        // a capsule that is configured to collide with collectables, enemies and walls
        
        let (min, max) = node.boundingBox
        let collisionCapsuleRadius = CGFloat(max.x - min.x) * 0.4
        let collisionCapsuleHeight = CGFloat(max.y - min.y)
        
        let characterCollisionNode = SCNNode()
        characterCollisionNode.name = "collider"
        characterCollisionNode.position = SCNVector3(0.0, collisionCapsuleHeight * 0.51, 0.0) // a bit too high so that the capsule does not hit the floor
        characterCollisionNode.physicsBody = SCNPhysicsBody(type: .Kinematic, shape:SCNPhysicsShape(geometry: SCNCapsule(capRadius: collisionCapsuleRadius, height: collisionCapsuleHeight), options:nil))
        characterCollisionNode.physicsBody!.contactTestBitMask = BitmaskSuperCollectable | BitmaskCollectable | BitmaskCollision | BitmaskEnemy
        node.addChildNode(characterCollisionNode)
        
        
        // MARK: Load particle systems
        
        // Particle systems were configured in the SceneKit Scene Editor
        // They are retrieved from the scene and their birth rate are stored for later use
        
        func particleEmitterWithName(name: String) -> ParticleEmitter {
            let emitter: ParticleEmitter
            emitter.node = characterTopLevelNode.childNodeWithName(name, recursively:true)!
            emitter.particleSystem = emitter.node.particleSystems![0]
            emitter.birthRate = emitter.particleSystem.birthRate
            emitter.particleSystem.birthRate = 0
            emitter.node.hidden = false
            return emitter
        }
        
        fireEmitter = particleEmitterWithName("fire")
        smokeEmitter = particleEmitterWithName("smoke")
        whiteSmokeEmitter = particleEmitterWithName("whiteSmoke")
        
        
        // MARK: Load sound effects
        
        reliefSound = SCNAudioSource(name: "aah_extinction.mp3", volume: 2.0)
        haltFireOnTailSound = SCNAudioSource(name: "fire_extinction.mp3", volume: 2.0)
        catchTailOnFireSound = SCNAudioSource(name: "ouch_firehit.mp3", volume: 2.0)
        
        for i in 0..<10 {
            if let grassSound = SCNAudioSource(named: "game.scnassets/sounds/Step_grass_0\(i).mp3") {
                grassSound.volume = 0.5
                grassSound.load()
                steps[GroundType.Grass.rawValue].append(grassSound)
            }
            
            if let rockSound = SCNAudioSource(named: "game.scnassets/sounds/Step_rock_0\(i).mp3") {
                rockSound.load()
                steps[GroundType.Rock.rawValue].append(rockSound)
            }
            
            if let waterSound = SCNAudioSource(named: "game.scnassets/sounds/Step_splash_0\(i).mp3") {
                waterSound.load()
                steps[GroundType.Water.rawValue].append(waterSound)
            }
        }
        
        
        // MARK: Configure animations
        
        // Some animations are already there and can be retrieved from the scene
        // The "walk" animation is loaded from a file, it is configured to play foot steps at specific times during the animation
        
        characterTopLevelNode.enumerateChildNodesUsingBlock { (child, _) in
            for key in child.animationKeys {                // for every animation key
                let animation = child.animationForKey(key)! // get the animation
                animation.usesSceneTimeBase = false         // make it system time based
                animation.repeatCount = Float.infinity      // make it repeat forever
                child.addAnimation(animation, forKey: key)  // animations are copied upon addition, so we have to replace the previous animation
            }
        }
        
        walkAnimation = CAAnimation.animationWithSceneNamed("game.scnassets/walk.scn")
        walkAnimation.usesSceneTimeBase = false
        walkAnimation.fadeInDuration = 0.3
        walkAnimation.fadeOutDuration = 0.3
        walkAnimation.repeatCount = Float.infinity
        walkAnimation.speed = FoxCharacter.speedFactor
        walkAnimation.animationEvents = [
            SCNAnimationEvent(keyTime: 0.1) { (_, _, _) in self.playFootStepSound() },
            SCNAnimationEvent(keyTime: 0.6) { (_, _, _) in self.playFootStepSound() }]
    }
    
    // MARK: Retrieving nodes
    
    let node = SCNNode()
    
    // MARK: Controlling the character
    
    static let speedFactor = Float(1.538)
    
    private var groundType = GroundType.InTheAir
    private var previousUpdateTime = NSTimeInterval(0.0)
    private var accelerationY = SCNFloat(0.0) // Simulate gravity
    
    private var directionAngle: SCNFloat = 0.0 {
        didSet {
            if directionAngle != oldValue {
                node.runAction(SCNAction.rotateToX(0.0, y: CGFloat(directionAngle), z: 0.0, duration: 0.1, shortestUnitArc: true))
            }
        }
    }
    
    func walkIntoGround(direction: float3, time: NSTimeInterval, scene: SCNScene, groundTypeFromMaterial: SCNMaterial -> GroundType) -> SCNNode? {
        // delta time since last update
        if previousUpdateTime == 0.0 {
            previousUpdateTime = time
        }
        
        let deltaTime = Float(min(time - previousUpdateTime, 1.0 / 60.0))
        let characterSpeed = deltaTime * FoxCharacter.speedFactor * 0.84
        previousUpdateTime = time
        
        let initialPosition = node.position
        
        // move
        if direction.x != 0.0 && direction.z != 0.0 {
            // move character
            let position = float3(node.position)
            node.position = SCNVector3(position + direction * characterSpeed)
            
            // update orientation
            directionAngle = SCNFloat(atan2(direction.x, direction.z))
            
            isWalking = true
        }
        else {
            isWalking = false
        }
        
        // Update the altitude of the character
        
        var position = node.position
        var p0 = position
        var p1 = position
        
        let maxRise = SCNFloat(0.08)
        let maxJump = SCNFloat(10.0)
        p0.y -= maxJump
        p1.y += maxRise
        
        // Do a vertical ray intersection
        var groundNode: SCNNode?
        let results = scene.physicsWorld.rayTestWithSegmentFromPoint(p1, toPoint: p0, options:[SCNPhysicsTestCollisionBitMaskKey: BitmaskCollision | BitmaskWater, SCNPhysicsTestSearchModeKey: SCNPhysicsTestSearchModeClosest])
        
        if let result = results.first {
            var groundAltitude = result.worldCoordinates.y
            groundNode = result.node
            
            let groundMaterial = result.node.childNodes[0].geometry!.firstMaterial!
            groundType = groundTypeFromMaterial(groundMaterial)
            
            if groundType == .Water {
                if isBurning {
                    haltFireOnTail()
                }
                
                // do a new ray test without the water to get the altitude of the ground (under the water).
                let results = scene.physicsWorld.rayTestWithSegmentFromPoint(p1, toPoint: p0, options:[SCNPhysicsTestCollisionBitMaskKey: BitmaskCollision, SCNPhysicsTestSearchModeKey: SCNPhysicsTestSearchModeClosest])
                
                let result = results[0]
                groundAltitude = result.worldCoordinates.y
            }
            
            let threshold = SCNFloat(1e-5)
            let gravityAcceleration = SCNFloat(0.18)
            
            if groundAltitude < position.y - threshold {
                accelerationY += SCNFloat(deltaTime) * gravityAcceleration // approximation of acceleration for a delta time.
                if groundAltitude < position.y - 0.2 {
                    groundType = .InTheAir
                }
            }
            else {
                accelerationY = 0
            }
            
            position.y -= accelerationY
            
            // reset acceleration if we touch the ground
            if groundAltitude > position.y {
                accelerationY = 0
                position.y = groundAltitude
            }
            
            // Finally, update the position of the character.
            node.position = position
            
        }
        else {
            // no result, we are probably out the bounds of the level -> revert the position of the character.
            node.position = initialPosition
        }
        
        return groundNode
    }
    
    // MARK: Animating the character
    
    private var walkAnimation: CAAnimation!
    
    private var isWalking: Bool = false {
        didSet {
            if oldValue != isWalking {
                // Update node animation.
                if isWalking {
                    node.addAnimation(walkAnimation, forKey: "walk")
                } else {
                    node.removeAnimationForKey("walk", fadeOutDuration: 0.2)
                }
            }
        }
    }
    
    private var walkSpeed: Float = WalkSpeed.Normal.rawValue {
        didSet {
            // remove current walk animation if any.
            let wasWalking = isWalking
            if wasWalking {
                isWalking = false
            }

            walkAnimation.speed = FoxCharacter.speedFactor * walkSpeed
            
            // restore walk animation if needed.
            isWalking = wasWalking
        }
    }
    
    // MARK: Dealing with fire
    
    private var isBurning = false
    private var isInvincible = false
    
    private var fireEmitter: ParticleEmitter! = nil
    private var smokeEmitter: ParticleEmitter! = nil
    private var whiteSmokeEmitter: ParticleEmitter! = nil
    
    func catchTailOnFire() {
        if isInvincible == false {
            isInvincible = true
            node.runAction(SCNAction.sequence([
                SCNAction.playAudioSource(catchTailOnFireSound, waitForCompletion: false),
                SCNAction.repeatAction(SCNAction.sequence([
                    SCNAction.fadeOpacityTo(0.01, duration: 0.1),
                    SCNAction.fadeOpacityTo(1.0, duration: 0.1)
                    ]), count: 7),
                SCNAction.runBlock { _ in self.isInvincible = false } ]))
        }
        
        isBurning = true
        
        startFireAndSmoke()
        walkFaster()
    }
    
    func haltFireOnTail() {
        if isBurning {
            isBurning = false
            playHaltFireSounds()
            stopFireAndSmoke()
            startWhiteSmoke()
            progressivelyStopWhiteSmoke()
            walkNormally()
        }
    }
    
    private func playHaltFireSounds() {
        node.runAction(SCNAction.sequence([
            SCNAction.playAudioSource(haltFireOnTailSound, waitForCompletion: true),
            SCNAction.playAudioSource(reliefSound, waitForCompletion: false)])
        )
    }
    
    private func startFireAndSmoke() {
        fireEmitter.particleSystem.birthRate = fireEmitter.birthRate
        smokeEmitter.particleSystem.birthRate = smokeEmitter.birthRate
    }
    
    private func stopFireAndSmoke() {
        fireEmitter.particleSystem.birthRate = 0
        SCNTransaction.animateWithDuration(1.0) {
            self.smokeEmitter.particleSystem.birthRate = 0
        }
    }
    
    private func startWhiteSmoke() {
        whiteSmokeEmitter.particleSystem.birthRate = whiteSmokeEmitter.birthRate
    }
    
    private func progressivelyStopWhiteSmoke() {
        SCNTransaction.animateWithDuration(5.0) {
            self.whiteSmokeEmitter.particleSystem.birthRate = 0
        }
    }
    
    private func walkNormally() {
        walkSpeed = WalkSpeed.Normal.rawValue
    }
    
    private func walkFaster() {
        walkSpeed = WalkSpeed.Fast.rawValue
    }
    
    // MARK: Dealing with sound
    
    private var reliefSound: SCNAudioSource
    private var haltFireOnTailSound: SCNAudioSource
    private var catchTailOnFireSound: SCNAudioSource
    
    private var steps = [[SCNAudioSource]](count: GroundType.Count.rawValue, repeatedValue: [])
    
    private func playFootStepSound() {
        if groundType != .InTheAir { // We are in the air, no sound to play.
            // Play a random step sound.
            let soundsCount = steps[groundType.rawValue].count
            let stepSoundIndex = min(soundsCount - 1, Int(Float(rand()) / Float(RAND_MAX) * Float(soundsCount)))
            node.runAction(SCNAction.playAudioSource(steps[groundType.rawValue][stepSoundIndex], waitForCompletion: false))
        }
    }
    
    // MARK: Reset states
    
    func resetStates() {
        replacementPosition = nil
        maxPenetrationDistance = 0
    }
    
}

extension FoxCharacter {
    func characterNode(characterNode: SCNNode, hitWall wall: SCNNode, withContact contact: SCNPhysicsContact) {
        if characterNode.parentNode != node {
            return
        }
        
        if maxPenetrationDistance > contact.penetrationDistance {
            return
        }
        
        maxPenetrationDistance = contact.penetrationDistance
        
        var characterPosition = float3(node.position)
        var positionOffset = float3(contact.contactNormal) * Float(contact.penetrationDistance)
        positionOffset.y = 0
        characterPosition += positionOffset
        
        replacementPosition = SCNVector3(characterPosition)
    }
}

extension FoxCharacter {
    func adjustPosition() {
        // If we hit a wall, position needs to be adjusted
        if let position = replacementPosition {
            node.position = position
        }
    }
}
