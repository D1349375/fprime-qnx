#ifndef M2_GATE_STATUS_HPP
#define M2_GATE_STATUS_HPP

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <thread>

#include <sys/iofunc.h>
#include <sys/dispatch.h>

namespace M2 {

struct CycleRecord;

// Diagnostic resource manager. The flight thread never accesses this object.
class GateStatus final {
  public:
    GateStatus() = default;
    ~GateStatus();

    bool start();
    void observe(const CycleRecord& row);

  private:
    struct Device {
        iofunc_attr_t attr{};
        GateStatus* owner = nullptr;
    };

    struct OpenFile {
        iofunc_ocb_t ocb{};
        char snapshot[256]{};
        std::size_t length = 0;
    };

    static int openReadOnly(resmgr_context_t* context, io_open_t* request, iofunc_attr_t* attr, void* extra);
    static int read(resmgr_context_t* context, io_read_t* request, iofunc_ocb_t* ocb);
    static int rejectWrite(resmgr_context_t*, io_write_t*, iofunc_ocb_t*);
    static iofunc_ocb_t* allocateFile(resmgr_context_t*, iofunc_attr_t* attr);
    static void freeFile(iofunc_ocb_t* ocb);

    void serve();
    void snapshot(OpenFile& file);

    std::mutex m_lock;
    const char* m_advisor = "waiting";
    const char* m_source = "FDIR";
    const char* m_decision = "NONE";
    const char* m_decisionSource = "NONE";
    std::uint64_t m_session = 0;
    std::uint64_t m_rejections = 0;

    Device m_device;
    iofunc_funcs_t m_ocbFunctions{};
    iofunc_mount_t m_mount{};
    resmgr_connect_funcs_t m_connect{};
    resmgr_io_funcs_t m_io{};
    dispatch_t* m_dispatch = nullptr;
    dispatch_context_t* m_context = nullptr;
    int m_attachId = -1;
    std::atomic<bool> m_stopping{false};
    std::thread m_thread;
};

}  // namespace M2

#endif
