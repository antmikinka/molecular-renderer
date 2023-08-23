//
//  Renderer.swift
//  MolecularRenderer
//
//  Created by Philip Turner on 2/22/23.
//

import AppKit
import Atomics
import KeyCodes
import Metal
import MolecularRenderer
import OpenMM
import simd

class Renderer {
  unowned let coordinator: Coordinator
  unowned let eventTracker: EventTracker
  
  // Rendering resources.
  var renderSemaphore: DispatchSemaphore = .init(value: 3)
  var renderingEngine: MRRenderer!
  
  // Geometry providers.
  var atomProvider: MRAtomProvider!
  var styleProvider: MRAtomStyleProvider!
  var animationFrameID: Int = 0
  var gifSerializer: GIFSerializer!
  var serializer: Serializer!
  
  // Camera scripting settings.
  static let recycleSimulation: Bool = true
  static let productionRender: Bool = true
  static let programCamera: Bool = true
  
  init(coordinator: Coordinator) {
    self.coordinator = coordinator
    self.eventTracker = coordinator.eventTracker
    
    var imageSize: Int
    var upscaleFactor: Int?
    if Self.productionRender {
      imageSize = Int(640)
      upscaleFactor = nil
    } else {
      imageSize = Int(ContentView.size)
      upscaleFactor = ContentView.upscaleFactor
    }
    
    let url = Bundle.main.url(
      forResource: "MolecularRendererGPU", withExtension: "metallib")!
    self.renderingEngine = MRRenderer(
      metallibURL: url,
      width: imageSize,
      height: imageSize,
      upscaleFactor: upscaleFactor,
      offline: Self.productionRender)
    self.gifSerializer = GIFSerializer(
      path: "/Users/philipturner/Documents/OpenMM/Renders/Exports")
    self.serializer = Serializer(
      renderer: self,
      path: "/Users/philipturner/Documents/OpenMM/Renders/Exports")
    self.styleProvider = NanoStuff()
    initOpenMM()
    
//    self.atomProvider = ExampleProviders.strainedShellStructure()
    
    self.ioSimulation()
    
    
//    fatalError("Working on development of wavefunction renderer")
  }
}

extension Renderer {
  func renderSimulation(
    _ simulation: MRSimulation
  ) {
    func getFramesPerFrame(psPerSecond: Double? = nil) -> Int {
      if let psPerSecond {
        let fsPerFrame = simulation.frameTimeInFs
        var framesPerFrame = psPerSecond * 1000 / 20 / fsPerFrame
        if abs(framesPerFrame - rint(framesPerFrame)) < 0.001 {
          framesPerFrame = rint(framesPerFrame)
        } else {
          fatalError(
            "Indivisible playback speed: \(psPerSecond) / 20 / \(fsPerFrame)")
        }
        return Int(framesPerFrame)
      } else {
        return 120 / 20
      }
    }
    let framesPerFrame = getFramesPerFrame()
    
    let numFrames = simulation.frameCount / framesPerFrame
    for frameID in 0..<numFrames {
      self.renderSemaphore.wait()
      let timeDouble = Double(frameID) / 20
      print("Timestamp: \(String(format: "%.2f", timeDouble))")
      
      let time = MRTimeContext(
        absolute: frameID * framesPerFrame,
        relative: framesPerFrame,
        frameRate: 20 * framesPerFrame)
      
      self.prepareRendering(
        animationTime: time,
        fov: 90,
        position: [0, 0, 0],
        rotation: PlayerState.makeRotation(azimuth: 0),
        frameID: frameID,
        framesPerSecond: 20)
      
      renderingEngine.render { pixels in
        self.gifSerializer.addImage(pixels: pixels)
        self.renderSemaphore.signal()
      }
    }
    renderingEngine.stopRendering()
    
    // The encoder from the Swift GIF package is very slow; we might need to
    // fork the repository and speed it up. The encoding is faster when the
    // image isn't completely blank.
    print("ETA: \(numFrames / 4) - \(numFrames) seconds.")
    gifSerializer.save(fileName: "SavedSimulation")
    print("Saved the production render.")
    exit(0)
  }
  
  func update() {
    self.renderSemaphore.wait()
    
    let frameDelta = coordinator.vsyncHandler.updateFrameID()
    let frameID = coordinator.vsyncHandler.frameID
    let irlTime = MRTimeContext(
      absolute: frameID,
      relative: frameDelta,
      frameRate: ContentView.frameRate)
    eventTracker.update(time: irlTime)
    
    var animationDelta: Int
    if eventTracker[.keyboardP].pressed {
      animationDelta = frameDelta
    } else {
      animationDelta = 0
    }
    if eventTracker[.keyboardR].pressed {
      animationDelta = 0
      animationFrameID = 0
    }
    animationFrameID += animationDelta
    let animationTime = MRTimeContext(
      absolute: animationFrameID,
      relative: animationDelta,
      frameRate: ContentView.frameRate)
    
    let playerState = eventTracker.playerState
    let progress = eventTracker.fovHistory.progress
    let fov = playerState.fovDegrees(progress: progress)
    
    let (azimuth, zenith) = playerState.rotations
    self.prepareRendering(
      animationTime: animationTime,
      fov: fov,
      position: playerState.position,
      rotation: azimuth * zenith,
      frameID: frameID,
      framesPerSecond: 120)
    
    let layer = coordinator.view.metalLayer!
    renderingEngine.render(layer: layer) {
      self.renderSemaphore.signal()
    }
  }
  
  private func prepareRendering(
    animationTime: MRTimeContext,
    fov: Float,
    position: SIMD3<Float>,
    rotation: simd_float3x3,
    frameID: Int,
    framesPerSecond: Int
  ) {
    renderingEngine.setGeometry(
      time: animationTime,
      atomProvider: &atomProvider,
      styleProvider: styleProvider)
    
    var _position = position
    var _rotation = rotation
    if Self.programCamera {
      let period: Float = 16.65 * 2
      let rotationCenter: SIMD3<Float> =  [0, 0, 0]
      let radius: Float = 3
      
      var angle = Float(frameID) / Float(framesPerSecond)
      angle /= period
      angle *= 2 * .pi
      
      let quaternion = simd_quatf(angle: -angle, axis: [0, 1, 0])
      let delta = simd_act(quaternion, [0, 0, 1])
      _position = rotationCenter + normalize(delta) * radius
      _rotation = PlayerState.makeRotation(azimuth: Double(-angle))
    }
    
    var lights: [MRLight] = []
    let cameraLight = MRLight(
      origin: _position, diffusePower: 1, specularPower: 1)
    lights.append(cameraLight)
    
    let quality = MRQuality(
      minSamples: 3, maxSamples: 7, qualityCoefficient: 30)
    renderingEngine.setCamera(
      fovDegrees: fov,
      position: _position,
      rotation: _rotation,
      lights: lights,
      quality: quality)
  }
  
  private func ioSimulation() {
    let simulationName = "SavedSimulation"
    if Self.recycleSimulation {
      let simulation = serializer.load(fileName: simulationName)
      self.atomProvider = SimulationAtomProvider(simulation: simulation)
      
      if Self.productionRender {
        renderSimulation(simulation)
      }
    } else {
      //    self.atomProvider = OctaneReference().provider
      //    self.atomProvider = DiamondoidCollision().provider
      //      self.atomProvider = VdwOscillator().provider
      
      serializer.save(
        fileName: simulationName,
        provider: atomProvider as! OpenMM_AtomProvider)
    }
  }
}
