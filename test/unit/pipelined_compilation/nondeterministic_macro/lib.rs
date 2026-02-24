use proc_macro::TokenStream;
use std::collections::HashMap;

/// A proc macro that produces non-deterministic output via HashMap iteration.
/// Different rustc invocations seed their HashMap randomizer differently, so
/// the generated method ordering varies across process boundaries, causing
/// different crate hashes (SVH) between separate compilations.
///
/// This is used to test that pipelined compilation handles SVH mismatches correctly.
#[proc_macro_derive(NonDeterministic)]
pub fn derive_nondeterministic(input: TokenStream) -> TokenStream {
    let input_str = input.to_string();

    // Use HashMap iteration (non-deterministic ordering) to generate impl blocks.
    let mut methods = HashMap::new();
    methods.insert("method_a", "42i32");
    methods.insert("method_b", "43i32");
    methods.insert("method_c", "44i32");
    methods.insert("method_d", "45i32");

    // Extract struct name (simplified parsing)
    let name = input_str
        .split("struct")
        .nth(1)
        .and_then(|s| {
            // For `struct Foo { ... }` use `{` as delimiter; for `struct Foo;` use `;`.
            if s.contains('{') {
                s.split('{').next()
            } else {
                s.split(';').next()
            }
        })
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "Unknown".to_string());

    let method_impls: String = methods
        .iter()
        .map(|(mname, val)| format!("    pub fn {}(&self) -> i32 {{ {} }}", mname, val))
        .collect::<Vec<_>>()
        .join("\n");

    format!("impl {} {{\n{}\n}}", name, method_impls)
        .parse()
        .unwrap()
}
