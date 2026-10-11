//! Volume counters need their own baseline: sysinfo's first delta can be the lifetime total.
//! Retain the last observed read-only flag with the same bounded volume identity.
use std::collections::HashMap;

use crate::model::DiskSnapshot;

type Identity = (String, String, String);

#[derive(Default)]
pub(super) struct DiskRates {
    previous: HashMap<Identity, (u64, u64, bool)>,
}

impl DiskRates {
    pub(super) fn update(&mut self, disks: &mut [DiskSnapshot], elapsed_seconds: f64) {
        self.update_with_read_only(disks, elapsed_seconds, |disk| {
            #[cfg(target_os = "linux")]
            {
                super::disk_read_only::current(std::path::Path::new(&disk.mount_point))
            }
            #[cfg(not(target_os = "linux"))]
            {
                Some(disk.is_read_only)
            }
        });
    }

    fn update_with_read_only(
        &mut self,
        disks: &mut [DiskSnapshot],
        elapsed_seconds: f64,
        mut read_only: impl FnMut(&DiskSnapshot) -> Option<bool>,
    ) {
        // Replace, rather than extend, so removal/reinsertion gets a fresh baseline and
        // the map stays bounded by the same collection limit as the outgoing report.
        let mut current = HashMap::with_capacity(disks.len());
        for disk in disks {
            let id = (
                disk.name.clone(),
                disk.mount_point.clone(),
                disk.file_system.clone(),
            );
            let counters = (disk.read_bytes_total, disk.written_bytes_total);
            let deltas = self.previous.get(&id).and_then(|previous| {
                Some((
                    counters.0.checked_sub(previous.0)?,
                    counters.1.checked_sub(previous.1)?,
                ))
            });
            let (read, written) = deltas.unwrap_or_default();
            disk.read_bytes_per_second = super::per_second(read, elapsed_seconds);
            disk.written_bytes_per_second = super::per_second(written, elapsed_seconds);
            // Linux sysinfo refreshes statvfs capacity but caches the first read-only flag.
            // A failed probe must preserve our last successful reading, not revert to that
            // initial flag. New volumes retain sysinfo's existing observation on failure.
            disk.is_read_only = read_only(disk)
                .or_else(|| self.previous.get(&id).map(|previous| previous.2))
                .unwrap_or(disk.is_read_only);
            current.insert(id, (counters.0, counters.1, disk.is_read_only));
        }
        self.previous = current;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn disk(read: u64, written: u64) -> DiskSnapshot {
        DiskSnapshot {
            name: "disk-a".into(),
            mount_point: "/media/disk-a".into(),
            file_system: "ext4".into(),
            total_bytes: 1_000_000_000_000,
            available_bytes: 500_000_000_000,
            read_bytes_total: read,
            written_bytes_total: written,
            read_bytes_per_second: 123.0,
            written_bytes_per_second: 456.0,
            is_read_only: false,
        }
    }

    #[test]
    fn newly_discovered_volume_does_not_report_lifetime_io_as_one_interval() {
        let mut rates = DiskRates::default();
        let mut values = [disk(512_000_000_000, 1_024_000_000_000)];
        rates.update(&mut values, 10.0);
        assert_eq!(values[0].read_bytes_total, 512_000_000_000);
        assert_eq!(values[0].read_bytes_per_second, 0.0);
        assert_eq!(values[0].written_bytes_per_second, 0.0);
        values[0].read_bytes_total += 1000;
        values[0].written_bytes_total += 2000;
        rates.update(&mut values, 10.0);
        assert_eq!(values[0].read_bytes_per_second, 100.0);
        assert_eq!(values[0].written_bytes_per_second, 200.0);
    }

    #[test]
    fn removal_reinsertion_and_counter_reset_reprime_the_baseline() {
        let mut rates = DiskRates::default();
        let mut values = [disk(u64::MAX - 100, u64::MAX - 100)];
        rates.update(&mut values, 10.0);
        values[0] = disk(50, 80); // Counter reset or wrap is not new I/O.
        rates.update(&mut values, 10.0);
        assert_eq!(values[0].read_bytes_per_second, 0.0);
        assert_eq!(values[0].written_bytes_per_second, 0.0);
        values[0] = disk(150, 280);
        rates.update(&mut values, 2.0);
        assert_eq!(values[0].read_bytes_per_second, 50.0);
        assert_eq!(values[0].written_bytes_per_second, 100.0);
        rates.update(&mut [], 10.0);
        assert!(rates.previous.is_empty());
        values[0] = disk(500_000, 900_000);
        rates.update(&mut values, 10.0);
        assert_eq!(values[0].read_bytes_per_second, 0.0);
        assert_eq!(values[0].written_bytes_per_second, 0.0);
    }

    #[test]
    fn remounted_volume_and_unchanged_counters_do_not_repeat_a_delta() {
        let mut rates = DiskRates::default();
        let mut values = [disk(100, 200)];
        rates.update(&mut values, 10.0);
        values[0] = disk(1100, 2200);
        rates.update(&mut values, 10.0);
        rates.update(&mut values, 10.0);
        assert_eq!(values[0].read_bytes_per_second, 0.0);
        values[0].mount_point = "/media/new-mount".into();
        values[0].read_bytes_total += 10_000;
        rates.update(&mut values, 10.0);
        assert_eq!(values[0].read_bytes_per_second, 0.0);
        assert_eq!(rates.previous.len(), 1);
    }

    #[test]
    fn read_only_changes_follow_current_mount_flags_without_resetting_io() {
        let mut rates = DiskRates::default();
        let mut values = [disk(100, 200)];
        for (read, written, current, expected) in [
            (100, 200, Some(false), false),
            (200, 400, Some(true), true),
            (300, 600, Some(true), true),
            (400, 800, Some(false), false),
        ] {
            values[0] = disk(read, written); // sysinfo's initial flag remains false.
            rates.update_with_read_only(&mut values, 10.0, |_| current);
            assert_eq!(values[0].is_read_only, expected);
            assert_eq!(
                values[0].read_bytes_per_second,
                if read == 100 { 0.0 } else { 10.0 }
            );
            assert_eq!(
                values[0].written_bytes_per_second,
                if read == 100 { 0.0 } else { 20.0 }
            );
        }
    }

    #[test]
    fn failed_read_only_probe_keeps_last_known_value_only_for_same_volume() {
        let mut rates = DiskRates::default();
        let mut values = [disk(100, 200)];
        rates.update_with_read_only(&mut values, 10.0, |_| Some(true));
        values[0].is_read_only = false; // The stale dependency value must not win.
        rates.update_with_read_only(&mut values, 10.0, |_| None);
        assert!(values[0].is_read_only);
        rates.update_with_read_only(&mut [], 10.0, |_| None);
        values[0].is_read_only = false;
        rates.update_with_read_only(&mut values, 10.0, |_| None);
        assert!(!values[0].is_read_only); // Removed identity does not leak into a new disk.
        values[0].is_read_only = true;
        values[0].mount_point = "/other".into();
        rates.update_with_read_only(&mut values, 10.0, |_| None);
        assert!(values[0].is_read_only); // New identity preserves either initial bool.
        assert_eq!(rates.previous.len(), 1);
    }
}
