import Darwin

/// Cached Mach ports.
///
/// `mach_host_self()` returns a send right and bumps its reference count on
/// every call, so calling it once per sample would slowly leak port references.
/// Both ports are process-global and immutable for our purposes.
public enum MachHost {
    public static let host: mach_port_t = mach_host_self()
    public static let task: mach_port_t = mach_task_self_

    /// The default processor set, used for live task and thread counts.
    public static let defaultProcessorSet: processor_set_name_t = {
        var pset: processor_set_name_t = 0
        guard processor_set_default(host, &pset) == KERN_SUCCESS else { return 0 }
        return pset
    }()

    /// Multiplier converting `mach_absolute_time()` ticks into nanoseconds.
    public static let machTicksToNanoseconds: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()

    /// Kernel page size; `vm_statistics64` counters are expressed in these.
    public static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        guard host_page_size(host, &size) == KERN_SUCCESS, size > 0 else { return 4096 }
        return UInt64(size)
    }()
}
