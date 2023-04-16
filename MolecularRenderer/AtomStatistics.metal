//
//  AtomStatistics.metal
//  MolecularRenderer
//
//  Created by Philip Turner on 4/6/23.
//

#ifndef ATOM_STATISTICS_H
#define ATOM_STATISTICS_H

#include <metal_stdlib>
using namespace metal;

struct AtomStatistics {
  // Color in RGB color space.
  packed_half3 color;

  // Radius in nm. We don't know the actual radius to 11 bits of precision, so
  // Float16 is fine.
  half radius;
};

struct BoundingBox {
  packed_float3 min;
  packed_float3 max;
};

struct Atom {
  packed_float3 origin;
  half radiusSquared;
  ushort element;
  
  Atom() {
    
  }
  
  Atom(float3 origin, ushort element, constant AtomStatistics* atomData) {
    this->origin = origin;
    this->element = element;
    
    half radius = this->getRadius(atomData);
    this->radiusSquared = radius * radius;
  }
  
  half getRadius(constant AtomStatistics* atomData) {
    return atomData[element].radius;
  }
  
  half3 getColor(constant AtomStatistics* atomData) {
    return atomData[element].color;
  }
  
  BoundingBox getBoundingBox(constant AtomStatistics* atomData) {
    half radius = this->getRadius(atomData);
    auto min = origin - float(radius);
    auto max = origin + float(radius);
    return BoundingBox {
      packed_float3(min),
      packed_float3(max)
    };
  }
};

#endif