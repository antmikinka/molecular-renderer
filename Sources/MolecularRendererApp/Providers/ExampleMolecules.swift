//
//  ExampleMolecules.swift
//  MolecularRenderer
//
//  Created by Philip Turner on 4/15/23.
//

import Foundation

struct ExampleMolecules {
  // Structure sourced from:
  // https://commons.wikimedia.org/wiki/File:Ethylene-CRC-MW-dimensions-2D-Vector.svg
  struct Ethylene: StaticAtomProvider {
    var atoms: [Atom]
    
    init() {
      let z_offset: Float = -1 // -2
      let c_offset_x: Float = 0.1339 / 2 // 0.20
      let carbon_origins: [SIMD3<Float>] = [
        SIMD3(-c_offset_x, 0, z_offset),
        SIMD3(+c_offset_x, 0, z_offset),
      ]
      
      let angle: Float = (180 - 121.3) * .pi / 180
      let h_offset_x: Float = 0.1087 * cos(angle) + c_offset_x // 0.50
      let h_offset_y: Float = 0.1087 * sin(angle) // 0.25
      let hydrogen_origins: [SIMD3<Float>] = [
        SIMD3(-h_offset_x, -h_offset_y, z_offset),
        SIMD3(-h_offset_x, +h_offset_y, z_offset),
        SIMD3(+h_offset_x, -h_offset_y, z_offset),
        SIMD3(+h_offset_x, +h_offset_y, z_offset),
      ]
      
      let atomData = GlobalStyleProvider.global.atomData
      self.atoms = hydrogen_origins.map {
        Atom(atomData: atomData, origin: $0, element: 1)
      }
      self.atoms += carbon_origins.map {
        Atom(atomData: atomData, origin: $0, element: 6)
      }
    }
  }
  
  struct TaggedEthylene: StaticAtomProvider {
    var atoms: [Atom]
    
    init() {
      let ethylene = Ethylene()
      self.atoms = ethylene.atoms
      
      let firstHydrogen = atoms.firstIndex(where: { $0.element == 1 })!
      let firstCarbon = atoms.firstIndex(where: { $0.element == 6 })!
      atoms[firstHydrogen].flags = 0x1 | 0x2
      atoms[firstCarbon].flags = 0x1 | 0x2
    }
  }
}
