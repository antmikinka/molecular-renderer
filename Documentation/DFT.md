# Density Functional Theory

Goal: Iron out a set of algorithms using Swift, Apple Accelerate, and the AMX coprocessor. Once they're tested, port necessary modules to C++, rocSOLVER, and HIP. Test Kahan block-summation algorithms that translate well between multiple vendors. Potentially prototype some in [metal-flash-attention](https://github.com/philipturner/metal-flash-attention), as the RDNA 3 matrix multiplication instruction has similar constraints to the Apple `simdgroup_matrix`. However, MFA has a battle-tested debugging suite for novel matmul algorithms.  Do not attempt to create matrix factorization kernels for the Apple GPU. Once the implementation is mature enough, rewrite the code from scratch and host it in [philipturner/density-functional-theory](https://github.com/philipturner/density-functional-theory).

Outcome: This should make proof-of-concept easier, compared to incubating it in code for alternative vendors I'm not very familiar with. Brings ability to design reaction sequences and pair them with ~million-atom materializations of assembler ideas. To create large-scale matter compilers from them (_Nanosystems 14.6.5_). Use this knowledge/experience to guide design of more manufacturable parts, and better CAD software for systems-level design.

## Technical Details

Goal: Combine a few recent breakthroughs in quantum chemistry. Do this with maximum possible CPU utilization and the simplest possible algorithms.
- [Effectively universal XC functional](https://www.science.org/doi/10.1126/science.abj6511) (2021)
  - More accurate than the B3LYP functional used for mechanosynthesis research, or at least not significantly worse.
  - The XC functional is often 90% of the maintenance and complexity of a DFT codebase. DeepMind's neural network makes the XC code ridiculously simple.
- [Dynamic precision for eigensolvers](https://pubs.acs.org/doi/10.1021/acs.jctc.2c00983) (2023)
  - Allows DFT to run on consumer hardware with limited FP64 units.
  - Use a similar solver described there, except replacing LOBPCG with LOBPCG II. This reduces bottlenecks from eigendecomposition (`eigh`) by 27x.
- [Real-space method achieving compute cost parity with plane-wave method](https://arxiv.org/pdf/2303.01937.pdf) (2023)
  - Real-space removes orbital basis sets, drastically simplifying the conceptual complexity.
  - Real-space removes the need for FFTs, both an additional library dependency and a bottleneck.
  - So far, every major commercial-quality codebase (GAUSSIAN, GAMESS) uses the plane-wave method. This CPU-designed algorithm isn't accelerator friendly, especially for medium-sized problems.
  - About the specific paper linked, I still lack a theoretical understanding of what implementation detail they were fixing. "8th order", "12th order", etc.

## Roadmap

Nowhere in the near future; 2024 at the earliest. The priority is getting supermassive systems on the molecular mechanics side, using the same superclusters described in this proposal.