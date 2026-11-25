#include "FlightDeployment/GateStatus.hpp"
#include "Components/FlightCycle/FlightCycle.hpp"

#include <algorithm>
#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <new>
#include <sys/mount.h>
#include <sys/neutrino.h>
#include <system_error>

namespace M2 {
namespace {

constexpr char GATE_PATH[] = "/dev/fprime/gate";

bool isDecision(const char* code) {
    return code[0] == 'R' || std::strcmp(code, "APPROVED") == 0;
}

}  // namespace

GateStatus::~GateStatus() {
    if (m_thread.joinable()) {
        m_stopping.store(true, std::memory_order_release);
        dispatch_unblock(m_context);
        m_thread.join();
    }
    if (m_attachId != -1) {
        resmgr_detach(m_dispatch, m_attachId, _RESMGR_DETACH_ALL | _RESMGR_DETACH_CLOSE);
    }
    if (m_context != nullptr) {
        dispatch_context_free(m_context);
    }
    if (m_dispatch != nullptr) {
        dispatch_destroy(m_dispatch);
    }
}

bool GateStatus::start() {
    const int channel = ChannelCreate(_NTO_CHF_FIXED_PRIORITY | _NTO_CHF_DISCONNECT | _NTO_CHF_UNBLOCK);
    if (channel == -1) {
        return false;
    }
    m_dispatch = dispatch_create_channel(channel, 0);
    if (m_dispatch == nullptr) {
        const int error = errno;
        ChannelDestroy(channel);
        errno = error;
        return false;
    }

    m_device.owner = this;
    iofunc_attr_init(&m_device.attr, S_IFCHR | 0444, nullptr, nullptr);
    iofunc_mount_init(&m_mount, sizeof(m_mount));
    m_mount.flags = _MOUNT_READONLY;
    m_ocbFunctions.nfuncs = _IOFUNC_NFUNCS;
    m_ocbFunctions.ocb_calloc = allocateFile;
    m_ocbFunctions.ocb_free = freeFile;
    m_mount.funcs = &m_ocbFunctions;
    m_device.attr.mount = &m_mount;

    iofunc_func_init(_RESMGR_CONNECT_NFUNCS, &m_connect, _RESMGR_IO_NFUNCS, &m_io);
    m_connect.open = openReadOnly;
    m_io.read = read;
    m_io.write = rejectWrite;
    resmgr_attr_t attributes{};
    attributes.nparts_max = 1;
    attributes.msg_max_size = 2048;
    m_attachId = resmgr_attach(m_dispatch, &attributes, GATE_PATH, _FTYPE_ANY, 0, &m_connect, &m_io, &m_device.attr);
    if (m_attachId == -1) {
        return false;
    }
    m_context = dispatch_context_alloc(m_dispatch);
    if (m_context == nullptr) {
        return false;
    }
    try {
        m_thread = std::thread(&GateStatus::serve, this);
    } catch (const std::system_error& error) {
        errno = error.code().value();
        return false;
    }
    return true;
}

void GateStatus::observe(const CycleRecord& row) {
    std::lock_guard<std::mutex> lock(m_lock);
    m_source = row.fdir ? "FDIR" : "ML";
    m_advisor = row.isolated ? "isolated" : row.fdir ? "unavailable" : "active";
    m_session = row.advice.session;
    if (row.gate[0] == 'R') {
        ++m_rejections;
    }
    if (isDecision(row.fdirGate)) {
        m_decision = row.fdirGate;
        m_decisionSource = "FDIR";
    } else if (isDecision(row.gate)) {
        m_decision = row.gate;
        m_decisionSource = "ML";
    }
}

void GateStatus::serve() {
    while (!m_stopping.load(std::memory_order_acquire)) {
        auto* context = dispatch_block(m_context);
        if (context != nullptr) {
            dispatch_handler(context);
        } else if (errno != EINTR) {
            std::perror("FlightSW gate status dispatch");
            break;
        }
    }
}

void GateStatus::snapshot(OpenFile& file) {
    std::lock_guard<std::mutex> lock(m_lock);
    const int size = std::snprintf(file.snapshot, sizeof(file.snapshot),
                                  "advisor=%s\ncontrol_source=%s\nsession=%" PRIu64 "\n"
                                  "last_decision=%s\nlast_decision_source=%s\nadvisor_rejections=%" PRIu64 "\n",
                                  m_advisor, m_source, m_session, m_decision, m_decisionSource, m_rejections);
    if (size > 0 && static_cast<std::size_t>(size) < sizeof(file.snapshot)) {
        file.length = static_cast<std::size_t>(size);
    }
}

iofunc_ocb_t* GateStatus::allocateFile(resmgr_context_t*, iofunc_attr_t* attr) {
    auto* file = new (std::nothrow) OpenFile;
    if (file == nullptr) {
        errno = ENOMEM;
        return nullptr;
    }
    reinterpret_cast<Device*>(attr)->owner->snapshot(*file);
    return &file->ocb;
}

void GateStatus::freeFile(iofunc_ocb_t* ocb) {
    delete reinterpret_cast<OpenFile*>(ocb);
}

int GateStatus::openReadOnly(resmgr_context_t* context, io_open_t* request, iofunc_attr_t* attr, void* extra) {
    if ((request->connect.ioflag & (_IO_FLAG_WR | O_CREAT | O_TRUNC | O_APPEND)) != 0) {
        return EROFS;
    }
    return iofunc_open_default(context, request, attr, extra);
}

int GateStatus::read(resmgr_context_t* context, io_read_t* request, iofunc_ocb_t* ocb) {
    const int status = iofunc_read_verify(context, request, ocb, nullptr);
    if (status != EOK) {
        return status;
    }
    if ((request->i.xtype & _IO_XTYPE_MASK) != _IO_XTYPE_NONE || ocb->offset < 0) {
        return EINVAL;
    }
    auto& file = *reinterpret_cast<OpenFile*>(ocb);
    if (static_cast<std::uint64_t>(ocb->offset) >= file.length) {
        _IO_SET_READ_NBYTES(context, 0);
        return EOK;
    }
    const auto offset = static_cast<std::size_t>(ocb->offset);
    const auto count = std::min<std::uint64_t>(_IO_READ_GET_NBYTES(request), file.length - offset);
    ocb->offset += static_cast<off_t>(count);
    _IO_SET_READ_NBYTES(context, count);
    return _RESMGR_PTR(context, file.snapshot + offset, count);
}

int GateStatus::rejectWrite(resmgr_context_t*, io_write_t*, iofunc_ocb_t*) {
    return EROFS;
}

}  // namespace M2
