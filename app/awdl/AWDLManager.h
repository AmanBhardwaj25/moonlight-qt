#pragma once

#if defined(Q_OS_DARWIN) || defined(__APPLE__)

// C++ interface — safe to include from plain .cpp files.
// All ObjC/XPC is hidden in AWDLManager.mm.
class AWDLManager {
public:
    static AWDLManager& instance();

    // Install the privileged helper (shows a one-time system auth dialog).
    // Call before the stream starts, from any thread — dispatches to main internally.
    // Returns false if the user denied authorization.
    bool ensureHelperInstalled();

    // Suppress AWDL for the duration of a stream.
    void suppress();

    // Restore AWDL (call on stream end).
    void restore();

    // Toggle mid-stream (keyboard shortcut).  Returns new suppressed state.
    bool toggle();

    bool isSuppressed() const { return m_suppressed; }

private:
    AWDLManager();
    ~AWDLManager();

    bool m_suppressed;
    bool m_helperReady;
    void* m_conn; // opaque NSXPCConnection*
};

#endif // Q_OS_DARWIN || __APPLE__
