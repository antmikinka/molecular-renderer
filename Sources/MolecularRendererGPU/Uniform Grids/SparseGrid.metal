//
//  SparseGrid.metal
//  MolecularRendererGPU
//
//  Created by Philip Turner on 7/15/23.
//

#include <metal_stdlib>
#include "../Utilities/Atomic.metal"
#include "../Utilities/FaultCounter.metal"
#include "UniformGrid.metal"
using namespace metal;

// The highest atom density is 176 atoms/nm^3 with diamond. An superdense carbon
// allotrope is theorized with 354 atoms/nm^3 (1), but the greatest superdense
// ones actually built are ~1-3% denser (2). 256 atoms/nm^3 is a close upper
// limit. It provides just enough room for overlapping atoms from nearby voxels
// (216-250 atoms/nm^3).
//
// (1) https://pubs.aip.org/aip/jcp/article-abstract/130/19/194512/296270/Structural-transformations-in-carbon-under-extreme?redirectedFrom=fulltext
// (2) https://www.newscientist.com/article/dn20551-new-super-dense-forms-of-carbon-outshine-diamond/

// 4x4x4 nm^3 voxels, 16384 atoms/voxel, <256 atoms/nm^3
constant uint upper_voxel_atoms_bits = 14;
constant uint upper_voxel_id_bits = 32 - upper_voxel_atoms_bits;
constant uint upper_voxel_id_mask = (1 << upper_voxel_id_bits) - 1;
constant uint upper_voxel_max_atoms = 1 << upper_voxel_atoms_bits;
constant uint equality_mask = 0x80000000;

// TODO: Profile whether 16-bit or 32-bit is faster.
typedef ushort atom_reference;

struct SparseGridArguments {
  // Grid position in world space and camera space.
  float3 upper_origin;
  ushort3 camera_upper_voxel;
  uint high_res_distance_sq;
  
  // Bounds of the sparse grid.
  uint max_upper_voxels;
  uint max_references;
  ushort3 upper_dimensions;
  ushort upper_plane_size;
  
private:
  ushort4 low_res_stats;
  ushort4 high_res_stats;
  
public:
  // Lower voxel size before 2x upscaling.
  ushort get_lower_width(bool is_high_res) const constant {
    if (is_high_res) {
      return high_res_stats[0];
    } else {
      return low_res_stats[0];
    }
  }
  
  half get_lower_scale(bool is_high_res) const constant {
    if (is_high_res) {
      return as_type<half>(high_res_stats[1]);
    } else {
      return as_type<half>(low_res_stats[1]);
    }
  }
  
  ushort get_num_voxel_slots(bool is_high_res) const constant {
    if (is_high_res) {
      return high_res_stats[2];
    } else {
      return low_res_stats[2];
    }
  }
};

#define SPARSE_BOX_GENERATE \
short3 s_min = short3(box.min); \
short3 s_max = short3(box.max); \
s_min = clamp(s_min, 0, max_coords); \
s_max = clamp(s_max, 0, max_coords); \
ushort3 box_min = ushort3(s_min); \
ushort3 box_max = ushort3(s_max); \

kernel void sparse_grid_pass1
(
 constant SparseGridArguments &args [[buffer(0)]],
 device MRAtomStyle *styles [[buffer(1)]],
 device MRAtom *atoms [[buffer(2)]],
 
 device atomic_uint *total_voxels [[buffer(3)]],
 device atomic_uint *upper_voxel_offsets [[buffer(4)]],
 device uint *upper_references [[buffer(5)]],
 device ushort4 *upper_voxel_coords [[buffer(6)]],
 device uint *lower_offset_offsets [[buffer(7)]],
 
 uint tid [[thread_position_in_grid]])
{
  MRAtom atom(atoms + tid);
  atom.origin = (atom.origin - args.upper_origin) / 4;
  MRBoundingBox box = atom.getBoundingBox(styles);
  
  short3 max_coords = short3(args.upper_dimensions - 1);
  SPARSE_BOX_GENERATE
  
  ushort3 permutation_mask;
#pragma clang loop unroll(full)
  for (ushort i = 0; i < 3; ++i) {
    permutation_mask[i] = (box_max[i] > box_min[i]);
  }
  
  ushort permutation_id = 0;
  ushort3 box_coords = box_min;
  while (permutation_id < 8) {
    uint address = box_coords.x + uint(args.upper_dimensions[0] * box_coords.y);
    address += args.upper_plane_size * box_coords.z;
#define object (upper_voxel_offsets + address)
    uint upper_voxel_id = atomic_load(object);
    
    short3 camera_delta = short3(args.camera_upper_voxel - box_coords);
    int camera_distance_sq = camera_delta.x * camera_delta.x;
    camera_distance_sq += camera_delta.y * camera_delta.y;
    camera_distance_sq += camera_delta.z * camera_delta.z;
    
    // TODO: Cull voxels outside the view frustum, and extend the cutoff.
    bool is_close = uint(camera_distance_sq) < args.high_res_distance_sq;
    ushort duplicates = is_close ? 2 : 1;
    
    FaultCounter counter(1000);
    while (upper_voxel_id < 2) {
      FAULT_COUNTER_RETURN(counter)
      
      uint expected = 0;
      uint desired = 1;
      if (atomic_compare_exchange(object, &expected, desired)) {
        ushort low_res_voxels = args.get_num_voxel_slots(false);
        ushort high_res_voxels = args.get_num_voxel_slots(true);
        high_res_voxels = (duplicates == 2) ? high_res_voxels : 0;
        uint lower_voxels = low_res_voxels + high_res_voxels;
        
        uint result1 = atomic_fetch_add(total_voxels + 0, duplicates);
        uint result2 = atomic_fetch_add(total_voxels + 4, lower_voxels);
        
        uint upper_voxel_id = 2 + result1;
        upper_voxel_coords[upper_voxel_id] = ushort4(box_coords, 0);
        lower_offset_offsets[upper_voxel_id] = result2;
        if (duplicates == 2) {
          result2 += low_res_voxels;
          upper_voxel_coords[upper_voxel_id + 1] = ushort4(box_coords, 1);
          lower_offset_offsets[upper_voxel_id + 1] = result2;
        }
        
        FaultCounter counter(10);
        uint expected = 1;
        while (!atomic_compare_exchange(object, &expected, result1)) {
          FAULT_COUNTER_RETURN(counter)
          expected = 1;
        }
      } else {
        upper_voxel_id = expected;
      }
    }
    upper_voxel_id &= upper_voxel_id_mask;
    
    if (upper_voxel_id < args.max_upper_voxels) {
      uint atom_id = atomic_fetch_add(object, 1 << upper_voxel_id_bits);
      atom_id >>= upper_voxel_id_bits;
      atom_id += upper_voxel_max_atoms * upper_voxel_id;
      
      // TODO: Check whether the sector's resolution matches that of the
      // current frame. Right now, we have no mechanism to check this.
      //
      // TODO: Compare against a sequence of 8-byte hashes, used as a direct
      // substitute for equality checking. Right now, the map doesn't exist,
      // so the flag is always off.
      uint reference = tid | (false ? equality_mask : 0);
      upper_references[atom_id] = reference;
      if (duplicates == 2) {
        upper_references[atom_id + upper_voxel_max_atoms] = reference;
      }
    }
    
    while (permutation_id < 8) {
      permutation_id += 1;
      ushort3 masks(1 << 0, 1 << 1, 1 << 2);
      box_coords = select(box_min, box_max, bool3(permutation_id & masks));
      if (all(box_coords <= box_max)) {
        break;
      }
    }
  }
}

#define SPARSE_BOX_LOOP(COORD) \
for (ushort COORD = box_min.COORD; COORD <= box_max.COORD; ++COORD) \

#define SPARSE_BOX_LOOP_START(WIDTH) \
ushort _address_z = VoxelAddress::generate(WIDTH, box_min); \
SPARSE_BOX_LOOP(z) { \
ushort _address_y = _address_z; \
SPARSE_BOX_LOOP(y) { \
ushort _address_x = 1 + (ushort(_address_y / 15) << 4); \
SPARSE_BOX_LOOP(x) { \
ushort slot_address = _address_x \

#define SPARSE_BOX_LOOP_END(WIDTH) \
_address_x += 1; \
if (_address_x % 16 == 0) { \
_address_x += 1; \
}\
} \
_address_y += VoxelAddress::increment_y(WIDTH); \
} \
_address_z += VoxelAddress::increment_z(WIDTH); \
} \

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wuninitialized"
kernel void sparse_grid_pass2
(
 constant SparseGridArguments &args [[buffer(0)]],
 device MRAtomStyle *styles [[buffer(1)]],
 device MRAtom *atoms [[buffer(2)]],
 
 device uint *upper_voxel_offsets [[buffer(4)]],
 device uint *upper_references [[buffer(5)]],
 device ushort4 *upper_voxel_coords [[buffer(6)]],
 device uint *lower_offset_offsets [[buffer(7)]],
 
 device MRAtom *upper_voxel_atoms [[buffer(8)]],
 device atomic_uint *total_references [[buffer(9)]],
 device atom_reference *lower_references [[buffer(10)]],
 device atom_reference *final_references [[buffer(11)]],
 
 // Stored linearly at a 2x2x2 granularity.
 device uint *lower_cache_offsets [[buffer(12)]],
 device vec<ushort, 8> *final_voxel_counts [[buffer(13)]],
 device vec<uint, 8> *final_voxel_offsets [[buffer(14)]],
 
 uint tgid [[threadgroup_position_in_grid]],
 ushort sidx [[simdgroup_index_in_threadgroup]],
 ushort lid [[thread_position_in_threadgroup]],
 ushort lane_id [[thread_index_in_simdgroup]])
{
  constexpr ushort tg_size = 384;
  constexpr ushort simds_per_group = tg_size / 32;
  threadgroup uint _scratch[32768 / 4];
  
  ushort4 raw_coords = upper_voxel_coords[2 + tgid];
  ushort3 voxel_coords = raw_coords.xyz;
  ushort row_size = args.upper_dimensions[0];
  uint address = voxel_coords.x + uint(row_size * voxel_coords.y);
  address += args.upper_plane_size * voxel_coords.z;
  
  uint raw_offset = upper_voxel_offsets[address];
  ushort atom_count = raw_offset >> upper_voxel_id_bits;
  if (atom_count == 0) {
    return;
  }
  
  bool is_high_res = raw_coords.w;
  uint voxel_offset = raw_offset & upper_voxel_id_mask;
  if (is_high_res) {
    voxel_offset += 1;
  }
  voxel_offset *= upper_voxel_max_atoms;
  
  // Check whether the equality succeeded.
  auto counters = _scratch + tgid % 47;
  {
    uint atom_offset = voxel_offset + lid;
    uint atom_end = voxel_offset + atom_count;
    uint references_mask = 0xFFFFFFFF;
    
    for (; atom_offset < atom_end; atom_offset += tg_size) {
      references_mask &= upper_references[atom_offset];
    }
    counters[sidx] = simd_and(references_mask);
  }
  
  threadgroup_barrier(mem_flags::mem_threadgroup);
  if (sidx == 0 && lane_id < simds_per_group) {
    uint references_mask = counters[lane_id];
    references_mask = simd_and(references_mask);
    uint succeeded = (references_mask >= equality_mask) ? 1 : 0;
    counters[lane_id] = succeeded;
  }
  
  threadgroup_barrier(mem_flags::mem_threadgroup);
  uint equality_succeeded = counters[sidx];
  if (equality_succeeded) {
    uint atom_offset = voxel_offset + lid;
    uint atom_end = voxel_offset + atom_count;
    for (; atom_offset < atom_end; atom_offset += tg_size) {
      // Copy the data from last frame.
    }
    return;
  }
  
  // Reserve the first bank for counters accessed very often.
  auto scratch = counters + 17;
  ushort virtual_lid = 1 + (lid / 15) * 16;
  ushort virtual_group_size = (tg_size / 15) * 16;
  
  constexpr ushort NUM_MISC_SLOTS = 3;
  ushort lower_width = args.get_lower_width(is_high_res);
  ushort max_coords = lower_width - 1;
  half scale = args.get_lower_scale(is_high_res);
  ushort num_voxel_slots = args.get_num_voxel_slots(is_high_res);
  {
    ushort num_slots = num_voxel_slots + NUM_MISC_SLOTS;
    for (ushort i = 0; i < num_slots; i += tg_size) {
      scratch[i] = 0;
    }
  }
  
  // Count the number of downscaled references.
  threadgroup_barrier(mem_flags::mem_threadgroup);
  {
    uint atom_offset = voxel_offset + lid;
    uint atom_end = voxel_offset + atom_count;
    float3 lower_voxel_origin = float(lower_width) * float3(voxel_coords);
    
    for (; atom_offset < atom_end; atom_offset += tg_size) {
      uint atom_id = upper_references[atom_offset];
      MRAtom atom(atoms + atom_id);
      atom.origin = scale * atom.origin - lower_voxel_origin;
      half radius = scale * atom.getRadius(styles);
      MRBoundingBox box { atom.origin - radius, atom.origin + radius };
      SPARSE_BOX_GENERATE
      
      SPARSE_BOX_LOOP_START(lower_width);
      atomic_fetch_add_(scratch + slot_address, 1);
      SPARSE_BOX_LOOP_END(lower_width);
      
      atom.radiusSquared = 4 * radius * radius;
      atom.origin *= 2;
      atom.store(upper_voxel_atoms + atom_id);
    }
  }
  
  constexpr uint offset_bits = 4 + upper_voxel_atoms_bits;
  constexpr uint offset_mask = (1 << offset_bits) - 1;
  threadgroup_barrier(mem_flags::mem_threadgroup);
  {
    ushort slot_id = virtual_lid;
    for (; slot_id < num_voxel_slots; slot_id += virtual_group_size) {
      uint count = scratch[slot_id];
      uint reduced = simd_prefix_exclusive_sum(count);

      uint threadgroup_offset;
      if (lane_id == 31) {
        uint sum = reduced + count;
        threadgroup_offset = atomic_fetch_add_(counters + 16, sum);
      }
      reduced += simd_broadcast(threadgroup_offset, 31);
      scratch[slot_id] = (count << offset_bits) | (reduced & offset_mask);
    }
  }
  
  // Clear the first counter.
  threadgroup_barrier(mem_flags::mem_threadgroup);
  if (sidx == 0) {
    uint group_offset = counters[16];
    uint device_offset;
    if (simd_is_first()) {
      device_offset = atomic_fetch_add(total_references + 0, group_offset);
    }
    device_offset = simd_broadcast_first(device_offset);
    if (lane_id < simds_per_group) {
      counters[lane_id] = device_offset;
    }
    counters[16] = 0;
  }
  
  threadgroup_barrier(mem_flags::mem_threadgroup);
  uint device_offset = counters[sidx];
  {
    uint atom_id = voxel_offset + lid;
    uint atom_end = voxel_offset + atom_count;
    for (; atom_id < atom_end; atom_id += tg_size) {
      MRAtom atom(upper_voxel_atoms + atom_id);
      atom.origin /= 2;
      half radius = atom.getRadius(styles);
      MRBoundingBox box { atom.origin - radius, atom.origin + radius };
      SPARSE_BOX_GENERATE
      
      SPARSE_BOX_LOOP_START(lower_width);
      uint offset = atomic_fetch_add_(scratch + slot_address, 1);
      offset = offset & offset_mask;
      offset += device_offset;
      
      ushort value = atom_id & (upper_voxel_max_atoms - 1);
      lower_references[offset] = value;
      SPARSE_BOX_LOOP_END(lower_width);
      
      // TODO: Write to a hash map.
    }
  }
  
  threadgroup_barrier(mem_flags::mem_threadgroup);
  {
    ushort slot_id = virtual_lid;
    for (; slot_id < num_voxel_slots; slot_id += virtual_group_size) {
      uint raw_offset = scratch[slot_id];
      uint count = raw_offset >> offset_bits;
      uint offset = raw_offset & offset_mask;
      scratch[slot_id] = offset - count;
    }
  }
  
  // Estimate the number of upscaled references.
  threadgroup_barrier(mem_flags::mem_threadgroup | mem_flags::mem_device);
  constexpr uint elements_per_cache_line = 128 / sizeof(atom_reference);
  constexpr uint address_bits = 13;
  constexpr uint address_mask = (1 << address_bits) - 1;
  uint lower_offset_offset = lower_offset_offsets[2 + tgid];
  {
    ushort plane_size = lower_width * lower_width;
    constexpr ushort3 block_span(4, 4, 2);
    ushort3 block_count = (lower_width + (block_span - 1)) / block_span;
    ushort3 id_in_block(lane_id % 4, (lane_id % 16) / 4, lane_id / 16);
    
    ushort3 block_id(sidx, 0, 0);
    FaultCounter counter(1000);
    for (; true; block_id.x += simds_per_group) {
      FAULT_COUNTER_RETURN(counter);
      
      while (block_id.x >= block_count.x) {
        block_id.x -= block_count.x;
        block_id.y += 1;
      }
      while (block_id.y >= block_count.y) {
        block_id.y -= block_count.y;
        block_id.z += 1;
      }
      if (block_id.z >= block_count.z) {
        break;
      }
      
      ushort3 coords = block_id * block_count + id_in_block;
      ushort address = coords.x + coords.y * lower_width;
      address += coords.z * plane_size;
      ushort slot_id = 1 + ((address / 15) << 4);
      
      uint offset = 0;
      uint next_offset = 0;
      if (all(coords < lower_width)) {
        offset = offset_mask & scratch[slot_id];
        uint next_slot = slot_id + 1;
        if (next_slot % 16 == 0) {
          next_slot += 1;
        }
        next_offset = offset_mask & scratch[next_slot];
      }
      
      ushort sub_voxel_counts[2][2][2];
#pragma clang loop unroll(full)
      for (ushort i = 0; i < 2; ++i) {
#pragma clang loop unroll(full)
        for (ushort j = 0; j < 2; ++j) {
#pragma clang loop unroll(full)
          for (ushort k = 0; k < 2; ++k) {
            sub_voxel_counts[i][j][k] = 0;
          }
        }
      }
      if (next_offset > offset) {
        offset += device_offset;
        next_offset += device_offset;
        
        for (; offset < next_offset; ++offset) {
          uint atom_id = voxel_offset + lower_references[offset];
          MRAtom atom(upper_voxel_atoms + atom_id);
          half radius = 2 * scale * atom.getRadius(styles);
          MRBoundingBox box { atom.origin - radius, atom.origin + radius };
          
          short3 s_min = short3(box.min) - short3(coords);
          short3 s_max = short3(box.max) - short3(coords);
          ushort3 box_min = ushort3(clamp(s_min, 0, 1));
          ushort3 box_max = ushort3(clamp(s_max, 0, 1));
          if (box_min.z == 0) {
            if (box_min.y == 0) {
              if (box_min.x == 0) { sub_voxel_counts[0][0][0] += 1; }
              if (box_max.x == 1) { sub_voxel_counts[0][0][1] += 1; }
            }
            if (box_max.y == 1) {
              if (box_min.x == 0) { sub_voxel_counts[0][1][0] += 1; }
              if (box_max.x == 1) { sub_voxel_counts[0][1][1] += 1; }
            }
          }
          if (box_max.z == 1) {
            if (box_min.y == 0) {
              if (box_min.x == 0) { sub_voxel_counts[1][0][0] += 1; }
              if (box_max.x == 1) { sub_voxel_counts[1][0][1] += 1; }
            }
            if (box_max.y == 1) {
              if (box_min.x == 0) { sub_voxel_counts[1][1][0] += 1; }
              if (box_max.x == 1) { sub_voxel_counts[1][1][1] += 1; }
            }
          }
        }
      }
      
      vec<ushort, 8> out;
#pragma clang loop unroll(full)
      for (ushort i = 0; i < 2; ++i) {
#pragma clang loop unroll(full)
        for (ushort j = 0; j < 2; ++j) {
#pragma clang loop unroll(full)
          for (ushort k = 0; k < 2; ++k) {
            out[i * 4 + j * 2 + k] = sub_voxel_counts[i][j][k];
          }
        }
      }
      uint _out_sum;
      {
        uint2 temp(out[0], out[1]);
        temp += uint2(out[2], out[3]);
        temp += uint2(out[4], out[5]);
        temp += uint2(out[6], out[7]);
        _out_sum = temp[0] + temp[1];
      }
      
      uint out_cache_lines = _out_sum + (elements_per_cache_line - 1);
      out_cache_lines /= elements_per_cache_line;
      uint is_occupied = out_cache_lines > 0;
      uint word = (out_cache_lines << address_bits) + is_occupied;
      uint compacted_word = simd_prefix_exclusive_sum(word);
      
      uint threadgroup_compacted;
      if (lane_id == 31) {
        uint sum = compacted_word + word;
        threadgroup_compacted = atomic_fetch_add_(counters + 16, sum);
      }
      compacted_word += simd_broadcast(threadgroup_compacted, 31);
      
      if (is_occupied) {
        uint compacted_address = compacted_word & address_mask;
        compacted_address = 1 + ((compacted_address / 15) << 4);
        uint operand = slot_id << offset_bits;
        atomic_fetch_or_(scratch + compacted_address, operand);
        
        uint cache_offset = compacted_word >> address_bits;
        uint offset_offset = lower_offset_offset + slot_id;
        lower_cache_offsets[offset_offset] = cache_offset;
        final_voxel_counts[offset_offset] = out;
      }
    }
  }
  
  threadgroup_barrier(mem_flags::mem_threadgroup);
  if (sidx == 0) {
    uint compacted_word = counters[16];
    uint group_offset = compacted_word >> address_bits;
    uint device_offset;
    if (simd_is_first()) {
      device_offset = atomic_fetch_add(total_references + 4, group_offset);
    }
    device_offset = simd_broadcast_first(device_offset);
    if (lane_id < simds_per_group) {
      counters[lane_id] = device_offset;
    }
  }
  
  // Generate the references, using an expensive atom-cell intersection test.
  threadgroup_barrier(mem_flags::mem_threadgroup | mem_flags::mem_device);
  uint occupied_voxels = counters[sidx] & address_mask;
  // TODO: Fetch extract "device_cache_offset" from counters[0].
  // TODO: Add the group cache offset to the device cache offset.
  {
    //    ushort address = 15 * ((slot_id - 1) / 16);
    //    ushort plane_size = lower_width * lower_width;
    //    ushort plane_id = address / plane_size;
    //    ushort remainder = address - plane_id * plane_size;
    //    ushort row_id = remainder / lower_width;
    //    ushort column_id = remainder - row_id * lower_width;
    //    float3 coords(column_id, row_id, plane_id);
    //    coords = coords * 2;
    
    // https://stackoverflow.com/questions/4578967/c
    // TODO: Store cube in sphere-space, pre-compute S - C.
  }
}
#pragma clang diagnostic pop
