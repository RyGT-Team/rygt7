#include "prx/libScePad/include/T300Protocol.hpp"
#include <cstdio>
#include <initializer_list>
#include <stdexcept>
#include <vector>
static void check(bool condition) {
    if (!condition)
        throw std::runtime_error("T300 protocol regression");
}
int main() {
    T300Protocol p;
    auto send = [&](std::initializer_list<unsigned char> x, unsigned now = 100) {
        std::vector<unsigned char> b(x);
        check(p.Report(b.data(), b.size(), now));
    };
    unsigned char feature[4] = {0xaa, 0xaa, 0xaa, 0xaa};
    check(T300Protocol::Feature(0x4e, feature, 2));
    check(feature[0] == 0x4e && feature[1] == 16 && feature[2] == 0xaa);
    check(!T300Protocol::Feature(0xff, feature, 2));
    send({0x33, 0x30, 0, 127});
    send({0x31, 1, 1, 0, 0xff, 0xff, 0, 0, 0, 0x30, 0, 0x40, 0, 0, 0});
    check(p.Decode(100).constant == 0);
    send({0x39, 1, 1, 1});
    check(p.Decode(100).constant == 32767);
    check(p.Decode(120000).constant == 32767);
    send({0x33, 0x30, 0, 129});
    check(p.Decode(100).constant == -32767);
    send({0x3b, 64});
    check(p.Decode(100).constant == -16383);
    send({0x39, 1, 0, 0});
    check(p.Decode(100).constant == 0);
    send({0x3b, 128});
    send({0x31, 1, 1, 0, 50, 0, 0, 0, 0, 0x30, 0, 0x40, 0, 0, 0});
    send({0x39, 1, 1, 1});
    check(p.Decode(149).constant == -32767);
    check(p.Decode(150).constant == 0);
    send({0x35, 0x50, 0, 40, 60, 0, 0, 0, 0, 80, 90});
    send({0x31, 2, 7, 0, 0xff, 0xff, 0, 0, 0, 0x50, 0, 0x60, 0, 0, 0});
    send({0x39, 2, 1, 1});
    check(p.Decode(100).spring == 60 * 32767 / 100);
    check(p.Decode(100).springLimit == 90 * 65535 / 100);
    send({0x48, 3});
    check(p.Decode(100).spring == 0);
    send({0x35, 0x30, 0, 100, 100, 0, 0, 0, 0, 20, 20});
    send({0x31, 1, 7, 0x40, 255, 255, 0, 255, 255, 0x30, 0, 0x40, 0, 0, 0});
    send({0x39, 1, 1, 1});
    check(p.Decode(100).spring == 32767);
    check(p.Decode(100).springLimit == 13107);
    check(p.Decode(180000).spring == 32767);
    send({0x33, 0x10, 0, 22});
    send({0x31, 0, 1, 0x40, 255, 255, 0, 255, 255, 0x10, 0, 0x20, 0, 0, 0}, 1000);
    send({0x39, 0, 1, 1}, 1000);
    check(p.Decode(1000).constant == 22 * 32767 / 127);
    check(p.Decode(200000).constant == 22 * 32767 / 127);
    send({0x31, 0, 1, 0x40, 255, 255, 0, 255, 255, 0x10, 0, 0x20, 0, 50, 0}, 1000);
    check(p.Decode(1049).constant == 0);
    check(p.Decode(1050).constant == 22 * 32767 / 127);
    unsigned char bad[64]{};
    for (int id : {0x31, 0x32, 0x33, 0x34, 0x35, 0x39}) {
        bad[0] = id;
        check(!p.Report(bad, 1, 100));
    }
    bad[0] = 0x31;
    bad[1] = 255;
    check(!p.Report(bad, 64, 100));
    bad[0] = 0x33;
    bad[1] = 255;
    bad[2] = 255;
    check(!p.Report(bad, 64, 100));
    puts("PASS: negotiation, signed force, gain, infinite/finite duration, stop, spring and malformed packets");
}
