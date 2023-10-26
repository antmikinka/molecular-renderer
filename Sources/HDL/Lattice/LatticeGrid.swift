//
//  LatticeGrid.swift
//  MolecularRenderer
//
//  Created by Philip Turner on 10/23/23.
//

protocol LatticeMask {
  associatedtype Storage: SIMD where Storage.Scalar == UInt8
  var mask: [Storage] { get set }
  
  init(dimensions: SIMD3<Int32>, origin: SIMD3<Float>, normal: SIMD3<Float>)
}

protocol LatticeGrid {
  associatedtype Mask: LatticeMask
  associatedtype Storage: SIMD where Storage.Scalar == Int8
  
  var dimensions: SIMD3<Int32> { get }
  var entityTypes: [Storage] { get set }
  
  // Dimensions may be in a different coordinate space than the bounds that are
  // entered by the user.
  init(bounds: SIMD3<Float>, material: MaterialType)
  mutating func replace(with other: Int8, where mask: Mask)
  
  var entities: [Entity] { get }
}

extension LatticeGrid {
  // Takes the normals for the 6 planes [-x, +x, -y, +y, -z, +z] and cuts the
  // atoms off the initial grid that need to be removed.
  mutating func initializeBounds(
    _ bounds: SIMD3<Float>, normals: [SIMD3<Float>]
  ) {
    for normalID in 0..<6 {
      var origin: SIMD3<Float> = .zero
      if normalID % 2 > 0 {
        origin = bounds
      }
      let normal = normals[normalID]
      let mask = Self.Mask(
        dimensions: self.dimensions, origin: origin, normal: normal)
      self.replace(with: 0, where: mask)
    }
  }
}