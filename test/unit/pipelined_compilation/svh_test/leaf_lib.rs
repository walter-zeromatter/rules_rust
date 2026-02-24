// Leaf library using a non-deterministic proc macro.
// When compiled twice (hollow rlib + full rlib), the proc macro runs with
// different HashMap seeds, potentially producing different SVH values.

#[derive(nondeterministic_macro::NonDeterministic)]
pub struct TypeA;

#[derive(nondeterministic_macro::NonDeterministic)]
pub struct TypeB;

pub fn value() -> i32 {
    TypeA.method_a() + TypeB.method_b()
}
