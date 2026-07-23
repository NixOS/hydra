use std::collections::BTreeSet;

use harmonia_store_derivation::derivation::Derivation;
use harmonia_store_derivation::derived_path::{OutputName, SingleDerivedPath};
use harmonia_store_path::StorePath;

/// Output names of intermediate derivations for a dynamic derivation
/// dependency, stored in reverse order so that the next level to resolve
/// can be cheaply `pop()`-ed.
///
/// e.g. for a derivation input that is `aaaa-dyn.drv^foo^bar^out`, the final
/// derivation would be `aaaa-dyn.drv^foo^bar` (no final `^out`). The output
/// names are stored as `["bar", "foo"]` (reversed).
///
/// In the common case of depending on a static derivation, this is empty.
#[derive(Debug, Clone, Default, PartialEq, Eq, PartialOrd, Ord)]
pub struct OutputNameChain(pub Vec<OutputName>);

impl OutputNameChain {
    pub fn pop(&mut self) -> Option<OutputName> {
        self.0.pop()
    }
}

/// Walk down the nesting of `sdp`, appending each output name onto `chain`.
/// Descending visits outermost names first, so plain pushes produce
/// [`OutputNameChain`]'s stack order.
fn flatten_into(
    mut sdp: &SingleDerivedPath,
    mut chain: OutputNameChain,
) -> (StorePath, OutputNameChain) {
    loop {
        match sdp {
            SingleDerivedPath::Opaque(p) => return (p.clone(), chain),
            SingleDerivedPath::Built { drv_path, output } => {
                chain.0.push(output.clone());
                sdp = drv_path;
            }
        }
    }
}

/// Flatten a [`SingleDerivedPath`] into `(root_drv_path, chain)`.
///
/// The output chain is in stack order (outermost first) matching
/// [`OutputNameChain`]'s convention. For `Built { Opaque(A), "foo" }`,
/// returns `(A, ["foo"])`. For `Opaque(A)`, returns `(A, [])`.
#[must_use]
pub fn flatten_path(sdp: &SingleDerivedPath) -> (StorePath, OutputNameChain) {
    flatten_into(sdp, OutputNameChain::default())
}

/// Like [`flatten_path`] but adds the outermost output name.
///
/// For `Built { Opaque(A), "foo" }` with output `"bar"`,
/// returns `(A, ["bar", "foo"])`.
#[must_use]
pub fn flatten_chain(
    drv_path: &SingleDerivedPath,
    output_name: &OutputName,
) -> (StorePath, OutputNameChain) {
    flatten_into(drv_path, OutputNameChain(vec![output_name.clone()]))
}

/// Extract `Built` input dependencies from a derivation.
///
/// Returns `(root_drv_path, relation)` pairs. `Opaque` (source) inputs are
/// skipped — only derivation build dependencies are returned. For each
/// `Built` input, the outermost output name (what we consume) is discarded;
/// intermediate output names form the [`OutputNameChain`].
pub fn input_drvs(drv: &Derivation) -> BTreeSet<(StorePath, OutputNameChain)> {
    drv.inputs
        .iter()
        .filter_map(|sdp| match sdp {
            SingleDerivedPath::Opaque(_) => None,
            SingleDerivedPath::Built { drv_path, .. } => Some(flatten_path(drv_path)),
        })
        .collect()
}
