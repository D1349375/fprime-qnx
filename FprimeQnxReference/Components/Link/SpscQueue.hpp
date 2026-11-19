#ifndef M2_SPSC_QUEUE_HPP
#define M2_SPSC_QUEUE_HPP

#include <array>
#include <atomic>
#include <cstddef>

namespace M2 {

//! Fixed-size, single-producer/single-consumer handoff with drop-newest behavior.
template <typename T, unsigned Capacity>
class SpscQueue {
    static_assert(Capacity > 0, "the queue needs at least one slot");
    static_assert(ATOMIC_INT_LOCK_FREE == 2, "flight handoff requires lock-free indices");

  public:
    bool push(const T& item) {
        const unsigned write = m_write.load(std::memory_order_relaxed);
        const unsigned next = (write + 1U) % (Capacity + 1U);
        if (next == m_read.load(std::memory_order_acquire)) {
            return false;
        }
        m_items[write] = item;
        m_write.store(next, std::memory_order_release);
        return true;
    }

    bool pop(T& item) {
        const unsigned read = m_read.load(std::memory_order_relaxed);
        if (read == m_write.load(std::memory_order_acquire)) {
            return false;
        }
        item = m_items[read];
        m_read.store((read + 1U) % (Capacity + 1U), std::memory_order_release);
        return true;
    }

  private:
    std::array<T, Capacity + 1U> m_items{};
    std::atomic<unsigned> m_read{0};
    std::atomic<unsigned> m_write{0};
};

}  // namespace M2

#endif
