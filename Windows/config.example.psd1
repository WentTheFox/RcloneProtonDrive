@{
    # Folder being synced, and the rclone remote (from rclone.conf) it syncs with.
    LocalPath   = 'D:\ProtonDrive'
    RemoteName  = 'proton:'

    # 'download' = one-way proton: -> LocalPath, never deletes locally (safe default).
    # 'bisync'   = two-way sync. Switch to this only after a few clean download cycles.
    Mode        = 'download'

    # Seconds between the *start* of one sync run and the next (if a run overruns
    # the interval, the next one starts immediately after it).
    IntervalSeconds = 900

    # rclone rc / web GUI bind address.
    RcAddr      = '127.0.0.1:5572'
}
