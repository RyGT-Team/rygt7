#pragma once
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

class T300Protocol {
public:
    static constexpr unsigned SlotCount = 16;
    struct Forces {
        bool active = false;
        int constant = 0, spring = 0, springCenter = 0, springLimit = 65535;
        int damper = 0, friction = 0;
    };
    static bool Feature(int id, std::uint8_t* out, std::size_t length) {
        if (!out || !length)
            return false;
        std::array<std::uint8_t, 64> data{};
        data[0] = static_cast<std::uint8_t>(id);
        switch (id) {
        case 0x49:
            data[1] = 1;
            break;
        case 0x4e:
            data[1] = SlotCount;
            break;
        case 0x4d:
            data[1] = 0x10;
            data[2] = 2;
            break;
        case 0x4a:
        case 0x4b:
        case 0x4c:
        case 0x4f:
            break;
        default:
            return false;
        }
        std::memset(out, 0, length);
        std::memcpy(out, data.data(), std::min(length, data.size()));
        return true;
    }

    bool Report(const std::uint8_t* r, std::size_t n, std::uint64_t now) {
        if (!r || !n)
            return false;
        switch (r[0]) {
        case 0x31: {
            if (n < 15 || r[1] >= SlotCount)
                return false;
            auto& s = slots[r[1]];
            s.type = r[2];
            s.duration = word(r + 4);
            s.address = word(r + 9);
            s.delay = word(r + 13);
            touched = true;
            return true;
        }
        case 0x32:
            return store(r, n, 9);
        case 0x33:
            return store(r, n, 4);
        case 0x34:
            return store(r, n, 8);
        case 0x35:
            return store(r, n, 11);
        case 0x39: {
            if (n < 4 || r[1] >= SlotCount)
                return false;
            auto& s = slots[r[1]];
            s.playing = (r[2] & 1) != 0;
            s.started = now;
            s.repeats = r[3];
            touched = true;
            return true;
        }
        case 0x3b:
            if (n < 2)
                return false;
            gain = std::min<unsigned>(r[1], 128);
            touched = true;
            return true;
        case 0x48:
            if (n < 2)
                return false;
            if (r[1] == 1 || r[1] == 3)
                for (auto& s : slots)
                    s.playing = false;
            touched = true;
            return true;
        default:
            return false;
        }
    }

    Forces Decode(std::uint64_t now) const {
        Forces f;
        f.active = touched;
        for (const auto& s : slots) {
            if (!s.playing || s.address >= memory.size())
                continue;
            const auto elapsed = now - s.started;
            if (elapsed < s.delay)
                continue;
            if (s.duration != 0xffff && s.repeats != 0 && elapsed - s.delay >= std::uint64_t(s.duration) * s.repeats)
                continue;
            const auto& p = memory[s.address];
            if (s.type == 1 && p.kind == 0x33) {
                f.constant += signedByte(p.bytes[0]) * 32767 / 127;
            } else if ((s.type == 7 || s.type == 8) && p.kind == 0x35) {
                const int k = std::clamp(std::max(signedByte(p.bytes[0]), signedByte(p.bytes[1])), 0, 100) * 32767 / 100;
                if (s.type == 7) {
                    f.spring = std::max(f.spring, k);
                    f.springCenter =
                        std::clamp(static_cast<int>(static_cast<std::int16_t>(word(p.bytes.data() + 2))), -500, 500) * 32767 / 500;
                    f.springLimit = std::min<int>(std::max(p.bytes[6], p.bytes[7]), 100) * 65535 / 100;
                } else
                    f.damper = std::max(f.damper, k);
            }
        }
        f.constant = std::clamp(f.constant, -32767, 32767) * gain / 128;
        f.spring = f.spring * gain / 128;
        f.damper = f.damper * gain / 128;
        return f;
    }

private:
    static unsigned word(const std::uint8_t* p) { return p[0] | unsigned(p[1]) << 8; }
    static int signedByte(std::uint8_t b) { return b < 128 ? b : int(b) - 256; }
    struct Slot {
        bool playing = false;
        unsigned type = 0, address = 0, duration = 0xffff, delay = 0, repeats = 0;
        std::uint64_t started = 0;
    };
    struct Parameter {
        std::uint8_t kind = 0;
        std::array<std::uint8_t, 8> bytes{};
    };
    std::array<Slot, SlotCount> slots{};
    std::array<Parameter, SlotCount * 32 + 16> memory{};
    int gain = 128;
    bool touched = false;
    bool store(const std::uint8_t* r, std::size_t n, std::size_t required) {
        if (n < required)
            return false;
        const auto address = word(r + 1);
        if (address >= memory.size())
            return false;
        auto& p = memory[address];
        p.kind = r[0];
        p.bytes = {};
        std::memcpy(p.bytes.data(), r + 3, required - 3);
        touched = true;
        return true;
    }
};
