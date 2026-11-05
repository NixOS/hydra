use std::collections::BTreeMap;

/// A worker registration, rather than a hostname shared by several workers.
pub(crate) trait Registration {
    fn registration_id(&self) -> &str;
}

pub(crate) fn by_registration<T: Registration>(
    machines: impl IntoIterator<Item = T>,
) -> BTreeMap<String, T> {
    machines
        .into_iter()
        .map(|machine| (machine.registration_id().to_owned(), machine))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{Registration, by_registration};

    #[derive(Clone, Debug, PartialEq, Eq)]
    struct Machine {
        id: &'static str,
        hostname: &'static str,
        system: &'static str,
        capacity: bool,
    }

    impl Registration for Machine {
        fn registration_id(&self) -> &str {
            self.id
        }
    }

    #[test]
    fn keeps_native_and_linux_registrations_on_the_same_host() {
        let native = Machine {
            id: "native-registration",
            hostname: "mac-6",
            system: "aarch64-darwin",
            capacity: true,
        };
        let linux = Machine {
            id: "linux-registration",
            hostname: "mac-6",
            system: "x86_64-linux",
            capacity: false,
        };
        let machines = by_registration([native.clone(), linux.clone()]);
        assert_eq!(machines.len(), 2);
        assert_eq!(machines["native-registration"], native);
        assert_eq!(machines["linux-registration"], linux);
        assert!(!machines.contains_key("mac-6"));
        assert_eq!(machines, by_registration([linux, native]));
    }

    #[test]
    fn empty_registry_stays_empty() {
        assert!(by_registration(Vec::<Machine>::new()).is_empty());
    }
}
