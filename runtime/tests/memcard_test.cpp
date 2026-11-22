#include "hw/memcard.h"
#include "runtime.h"
#include "platform.h"

#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

bool g_log_enabled[LOG_COUNT] = {};
void log_msg(LogCat, const char*, ...) {}

void plat_make_dirs(const std::string& path) {
    std::error_code error;
    std::filesystem::create_directories(path, error);
}

bool plat_replace_file(const char* from, const char* to) {
    std::error_code error;
    std::filesystem::remove(to, error);
    error.clear();
    std::filesystem::rename(from, to, error);
    return !error;
}

static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

static void send(MemCard& card, uint8_t byte) { (void)card.transfer(byte, false); }

static void address(MemCard& card, uint32_t value) {
    send(card, (uint8_t)((value >> 17) & 3));
    send(card, (uint8_t)(value >> 9));
    send(card, (uint8_t)((value >> 7) & 3));
    send(card, (uint8_t)(value & 0x7F));
}

static void program(MemCard& card, uint32_t offset, const std::vector<uint8_t>& bytes) {
    card.select();
    send(card, 0xF2);
    address(card, offset);
    for (uint8_t byte : bytes) send(card, byte);
    require(card.deselect(), "page program did not raise its enabled interrupt");
}

static std::vector<uint8_t> read_file(const std::filesystem::path& path) {
    std::ifstream file(path, std::ios::binary);
    require(bool(file), "could not open card image for reading");
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(file), {});
}

int main() {
    const auto root = std::filesystem::temp_directory_path() /
        ("sfa-memcard-test-" + std::to_string(static_cast<long long>(
            std::filesystem::file_time_type::clock::now().time_since_epoch().count())));
    const auto path = root / "saves" / "memcard_a.raw";
    try {
        MemCard card(path.string(), 4);
        constexpr size_t card_size = 512 * 1024;
        require(std::filesystem::file_size(path) == card_size, "formatted card is not exactly 512 KiB");
        auto bytes = read_file(path);
        require(bytes[0] || bytes[1] || bytes[2], "formatted card serial was left zero");

        program(card, 0x1234, {0x11, 0x22, 0x33});
        bytes = read_file(path);
        require(bytes.size() == card_size, "page program changed card size");
        require(bytes[0x1233] == 0xFF && bytes[0x1234] == 0x11 && bytes[0x1235] == 0x22 &&
                bytes[0x1236] == 0x33 && bytes[0x1237] == 0xFF, "page program changed the wrong bytes");

        program(card, 0x207F, {0xA1, 0xB2, 0xC3});
        bytes = read_file(path);
        require(bytes[0x207F] == 0xA1 && bytes[0x2000] == 0xB2 && bytes[0x2001] == 0xC3,
                "page program did not wrap within its 128-byte page");
        require(bytes[0x1FFF] == 0xFF && bytes[0x2080] == 0xFF, "wrapped page write crossed a page boundary");

        program(card, 0x4000, {0x55});
        bytes = read_file(path);
        const uint8_t before_sector = bytes[0x3F00];
        const uint8_t after_sector = bytes[0x6000];
        card.select();
        send(card, 0xF1);
        send(card, 0);
        send(card, 0x20); // 0x4000, then erase the containing 8 KiB sector.
        require(card.deselect(), "sector erase did not raise its enabled interrupt");
        bytes = read_file(path);
        for (size_t i = 0x4000; i < 0x6000; ++i) require(bytes[i] == 0xFF, "sector erase left a programmed byte");
        require(bytes[0x3F00] == before_sector && bytes[0x6000] == after_sector,
                "sector erase crossed its 8 KiB range");

        card.select();
        send(card, 0xF4);
        require(card.deselect(), "chip erase did not raise its enabled interrupt");
        bytes = read_file(path);
        require(bytes.size() == card_size, "chip erase changed card size");
        for (uint8_t byte : bytes) require(byte == 0xFF, "chip erase did not clear the complete card");

        MemCard reloaded(path.string(), 4);
        (void)reloaded;
        require(std::filesystem::file_size(path) == card_size, "reloaded card size changed");

        const auto short_path = root / "saves" / "short-card.raw";
        {
            std::ofstream short_card(short_path, std::ios::binary);
            std::array<uint8_t, 64> prefix{};
            prefix.fill(0x37);
            short_card.write(reinterpret_cast<const char*>(prefix.data()), prefix.size());
        }
        MemCard repaired(short_path.string(), 4);
        program(repaired, 0x100, {0x42});
        auto repaired_bytes = read_file(short_path);
        require(repaired_bytes.size() == card_size, "small write did not repair a truncated card image");
        require(repaired_bytes[0] == 0x37 && repaired_bytes[63] == 0x37 && repaired_bytes[0x100] == 0x42,
                "truncated card repair did not preserve loaded and newly written data");

        std::filesystem::remove_all(root);
        return 0;
    } catch (const std::exception& failure) {
        std::error_code cleanup_error;
        std::filesystem::remove_all(root, cleanup_error);
        std::cerr << "memcard test failed: " << failure.what() << '\n';
        return 1;
    }
}
