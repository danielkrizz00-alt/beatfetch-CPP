// BeatFetch (C++) — live terminal dashboard combining:
//   - fastfetch system info (auto-refreshing)
//   - currently playing music (via playerctl / MPRIS)
//   - a real-time audio spectrum visualizer (via cava)
//
// Requires: fastfetch (or hyfetch/neofetch), playerctl, cava.
// Build: make (see Makefile). Run: ./beatfetch

#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <sstream>
#include <string>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

static std::vector<std::string> splitLines(const std::string &s) {
    std::vector<std::string> out;
    std::string cur;
    for (char c : s) {
        if (c == '\n') { out.push_back(cur); cur.clear(); }
        else cur.push_back(c);
    }
    out.push_back(cur);
    return out;
}

static std::vector<std::string> splitChar(const std::string &s, char sep) {
    std::vector<std::string> out;
    std::string cur;
    for (char c : s) {
        if (c == sep) { out.push_back(cur); cur.clear(); }
        else cur.push_back(c);
    }
    out.push_back(cur);
    return out;
}

static std::string trim(const std::string &s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

static std::pair<int, std::string> execCapture(const std::vector<std::string> &args,
                                                int timeoutSec = 10) {
    int outPipe[2];
    if (pipe(outPipe) != 0) return {-1, ""};

    pid_t pid = fork();
    if (pid < 0) return {-1, ""};

    if (pid == 0) {
        dup2(outPipe[1], STDOUT_FILENO);
        dup2(outPipe[1], STDERR_FILENO);
        close(outPipe[0]);
        close(outPipe[1]);
        std::vector<char *> argv;
        for (auto &a : args) argv.push_back(const_cast<char *>(a.c_str()));
        argv.push_back(nullptr);
        execvp(argv[0], argv.data());
        _exit(127);
    }

    close(outPipe[1]);
    std::string output;
    char buf[4096];
    fcntl(outPipe[0], F_SETFL, O_NONBLOCK);
    auto start = std::chrono::steady_clock::now();
    int status = -1;
    bool exited = false;
    while (true) {
        ssize_t n = read(outPipe[0], buf, sizeof(buf));
        if (n > 0) {
            output.append(buf, n);
            continue;
        }
        if (!exited) {
            pid_t r = waitpid(pid, &status, WNOHANG);
            if (r == pid) exited = true;
        }
        if (n == 0 && exited) break;
        auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                           std::chrono::steady_clock::now() - start)
                           .count();
        if (elapsed > timeoutSec) {
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    close(outPipe[0]);
    int rc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    return {rc, output};
}

static bool commandExists(const std::string &name) {
    std::string path = getenv("PATH") ? getenv("PATH") : "";
    std::stringstream ss(path);
    std::string dir;
    while (std::getline(ss, dir, ':')) {
        std::string p = dir + "/" + name;
        if (access(p.c_str(), X_OK) == 0) return true;
    }
    return false;
}

static bool backendAvailable(const std::string &backend) {
    if (backend == "hyfetch") {
        if (!commandExists("python3")) return false;
        auto [rc, output] = execCapture({"python3", "-m", "hyfetch", "--help"}, 2);
        return rc == 0 || output.find("hyfetch") != std::string::npos;
    }
    return commandExists(backend);
}

struct NowPlaying {
    bool available = false;
    std::string fatal;
    std::string status, player, artist, title, album, posStr, lenStr;
    double ratio = 0.0;
};

struct AppState {
    std::mutex mtx;
    std::vector<std::string> fastfetchLines;
    std::string fastfetchError;
    NowPlaying nowPlaying;
    std::vector<int> bars;
    std::string cavaError;
    std::atomic<bool> stop{false};
    std::atomic<pid_t> cavaPid{-1};
};

static const char *STATUS_ICON(const std::string &s) {
    if (s == "Playing") return "\u25B6";
    if (s == "Paused") return "\u23F8";
    if (s == "Stopped") return "\u25A0";
    return "?";
}

static const int VU_GRADIENT[8][3] = {
    {0x00, 0xaf, 0x5f}, {0x5f, 0xaf, 0x00}, {0xaf, 0xaf, 0x00}, {0xd7, 0xaf, 0x00},
    {0xff, 0x87, 0x00}, {0xff, 0x5f, 0x00}, {0xff, 0x2f, 0x00}, {0xff, 0x00, 0x00},
};

static std::string fg(int r, int g, int b) {
    char buf[32];
    snprintf(buf, sizeof(buf), "\033[38;2;%d;%d;%dm", r, g, b);
    return buf;
}
static const std::string RESET = "\033[0m";
static const std::string BOLD = "\033[1m";
static const std::string ITALIC = "\033[3m";
static const std::string DIM = "\033[2m";

static std::vector<std::string> buildFetchCommand(const std::string &backend,
                                                   const std::vector<std::string> &extra) {
    std::vector<std::string> cmd;
    if (backend == "hyfetch") {
        cmd = {"python3", "-m", "hyfetch"};
    } else if (backend == "neofetch") {
        cmd = {"neofetch", "--stdout"};
    } else {
        cmd = {"fastfetch", "--pipe", "false"};
    }
    for (auto &e : extra) cmd.push_back(e);
    return cmd;
}

static void fastfetchWorker(AppState &state, double intervalSec, const std::string &backend,
                             std::vector<std::string> extraArgs) {
    auto cmd = buildFetchCommand(backend, extraArgs);
    while (!state.stop.load()) {
        auto [rc, output] = execCapture(cmd, 10);
        if (rc == 127 || (rc == -1 && output.empty())) {
            std::lock_guard<std::mutex> lk(state.mtx);
            state.fastfetchError = backend + " is not installed or not on PATH.";
            return;
        }
        {
            std::lock_guard<std::mutex> lk(state.mtx);
            state.fastfetchLines = splitLines(output);
            state.fastfetchError.clear();
        }
        (void)rc;
        for (double waited = 0; waited < intervalSec && !state.stop.load(); waited += 0.1)
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

static std::string fmtHms(const std::string &s) {
    std::string t = trim(s);
    return t.empty() ? "0:00" : t;
}

static void nowPlayingWorker(AppState &state, double intervalSec, const std::string &player) {
    const char SEP = '\x01';
    std::string fmt = std::string("{{status}}") + SEP + "{{playerName}}" + SEP + "{{artist}}" +
                       SEP + "{{title}}" + SEP + "{{album}}" + SEP + "{{duration(position)}}" +
                       SEP + "{{duration(mpris:length)}}" + SEP + "{{position}}" + SEP +
                       "{{mpris:length}}";
    std::vector<std::string> cmd = {"playerctl"};
    if (!player.empty()) { cmd.push_back("--player"); cmd.push_back(player); }
    cmd.push_back("metadata");
    cmd.push_back("--format");
    cmd.push_back(fmt);

    while (!state.stop.load()) {
        auto [rc, output] = execCapture(cmd, 5);
        if (rc == 127) {
            std::lock_guard<std::mutex> lk(state.mtx);
            state.nowPlaying = NowPlaying{};
            state.nowPlaying.fatal = "playerctl is not installed or not on PATH.";
            return;
        }
        while (!output.empty() && (output.back() == '\n')) output.pop_back();
        auto fields = splitChar(output, SEP);
        {
            std::lock_guard<std::mutex> lk(state.mtx);
            if (rc != 0 || fields.size() < 9 || fields[0].empty()) {
                state.nowPlaying = NowPlaying{};
            } else {
                NowPlaying np;
                np.available = true;
                np.status = fields[0];
                np.player = fields[1];
                np.artist = fields[2];
                np.title = fields[3];
                np.album = fields[4];
                np.posStr = fmtHms(fields[5]);
                np.lenStr = fmtHms(fields[6]);
                try {
                    double p = std::stod(fields[7]);
                    double l = std::stod(fields[8]);
                    np.ratio = (l > 0) ? std::max(0.0, std::min(1.0, p / l)) : 0.0;
                } catch (...) { np.ratio = 0.0; }
                state.nowPlaying = np;
            }
        }
        for (double waited = 0; waited < intervalSec && !state.stop.load(); waited += 0.1)
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

static std::string buildCavaConfig(int bars, int maxRange) {
    std::ostringstream ss;
    ss << "[general]\n"
       << "bars = " << bars << "\n"
       << "framerate = 60\n"
       << "autosens = 1\n"
       << "sensitivity = 100\n\n"
       << "[output]\n"
       << "method = raw\n"
       << "raw_target = /dev/stdout\n"
       << "data_format = ascii\n"
       << "ascii_max_range = " << maxRange << "\n"
       << "bar_delimiter = 59\n"
       << "frame_delimiter = 10\n\n"
       << "[smoothing]\n"
       << "monstercat = 1\n"
       << "noise_reduction = 77\n";
    return ss.str();
}

static void cavaWorker(AppState &state, int bars, int height) {
    if (!commandExists("cava")) {
        std::lock_guard<std::mutex> lk(state.mtx);
        state.cavaError = "cava is not installed or not on PATH.";
        return;
    }
    int maxRange = height * 8;
    std::string configText = buildCavaConfig(bars, maxRange);
    char tmpl[] = "/tmp/beatfetch_cava_XXXXXX";
    int fd = mkstemp(tmpl);
    if (fd < 0) {
        std::lock_guard<std::mutex> lk(state.mtx);
        state.cavaError = "failed to create cava config file.";
        return;
    }
    ssize_t wr = write(fd, configText.c_str(), configText.size());
    (void)wr;
    close(fd);
    std::string configPath = tmpl;

    int outPipe[2];
    if (pipe(outPipe) != 0) {
        std::lock_guard<std::mutex> lk(state.mtx);
        state.cavaError = "failed to create pipe for cava.";
        return;
    }
    pid_t pid = fork();
    if (pid == 0) {
        dup2(outPipe[1], STDOUT_FILENO);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) dup2(devnull, STDERR_FILENO);
        close(outPipe[0]); close(outPipe[1]);
        execlp("cava", "cava", "-p", configPath.c_str(), (char *)nullptr);
        _exit(127);
    }
    close(outPipe[1]);
    state.cavaPid.store(pid);

    FILE *fp = fdopen(outPipe[0], "r");
    char buf[8192];
    if (fp) {
        while (!state.stop.load() && fgets(buf, sizeof(buf), fp) != nullptr) {
            std::string l(buf);
            while (!l.empty() && (l.back() == '\n' || l.back() == ';' || l.back() == '\r'))
                l.pop_back();
            if (l.empty()) continue;
            auto parts = splitChar(l, ';');
            std::vector<int> values;
            bool ok = true;
            for (auto &p : parts) {
                if (p.empty()) continue;
                try { values.push_back(std::stoi(p)); }
                catch (...) { ok = false; break; }
            }
            if (ok && !values.empty()) {
                std::lock_guard<std::mutex> lk(state.mtx);
                state.bars = values;
                state.cavaError.clear();
            }
        }
        fclose(fp);
    }
    if (!state.stop.load()) {
        std::lock_guard<std::mutex> lk(state.mtx);
        state.cavaError = "cava exited unexpectedly. Is an audio server (PulseAudio/PipeWire) running?";
    }
    int status;
    kill(pid, SIGTERM);
    waitpid(pid, &status, 0);
    unlink(configPath.c_str());
}

static void getTermSize(int &cols, int &rows) {
    struct winsize w;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 && w.ws_col > 0) {
        cols = w.ws_col;
        rows = w.ws_row;
    } else {
        cols = 100;
        rows = 30;
    }
}

static void gotoRC(std::string &out, int row, int col) {
    out += "\033[" + std::to_string(row) + ";" + std::to_string(col) + "H";
}

static void drawPanelFrame(std::string &out, int x, int y, int w, int h,
                           const std::string &title, const std::string &borderColorEsc) {
    if (w < 4 || h < 3) return;
    gotoRC(out, y, x);
    out += borderColorEsc;
    out += "\u256D";
    for (int i = 1; i < w - 1; i++) out += "\u2500";
    out += "\u256E";
    out += RESET;

    if (!title.empty()) {
        gotoRC(out, y, x + 2);
        out += borderColorEsc + " " + title + " " + RESET;
    }

    for (int row = 1; row < h - 1; row++) {
        gotoRC(out, y + row, x);
        out += borderColorEsc + "\u2502" + RESET;
        gotoRC(out, y + row, x + w - 1);
        out += borderColorEsc + "\u2502" + RESET;
    }

    gotoRC(out, y + h - 1, x);
    out += borderColorEsc + "\u2570";
    for (int i = 1; i < w - 1; i++) out += "\u2500";
    out += "\u256F" + RESET;
}

static void drawContentLine(std::string &out, int x, int y, int w, int h, int contentRow,
                             const std::string &text, const std::string &borderColorEsc) {
    int row = y + 1 + contentRow;
    if (contentRow < 0 || contentRow > h - 3) return;
    gotoRC(out, row, x + 2);
    out += text;
    out += RESET;
    gotoRC(out, row, x + w - 1);
    out += borderColorEsc + "\u2502" + RESET;
}

static void centerMessage(std::string &out, int x, int y, int w, int h, const std::string &msg,
                           const std::string &styleEsc, const std::string &borderColorEsc) {
    int contentH = h - 2;
    int contentW = w - 4;
    int row = contentH / 2;
    int col = std::max(0, ((int)(contentW - (int)msg.size())) / 2);
    std::string line = styleEsc + msg + RESET;
    drawContentLine(out, x, y, w, h, row, std::string(col, ' ') + line, borderColorEsc);
}

static void buildFastfetchPanel(std::string &out, AppState &state, int x, int y, int w, int h) {
    const std::string border = fg(0, 190, 190);
    drawPanelFrame(out, x, y, w, h, BOLD + fg(0, 200, 200) + "system" + RESET, border);
    std::vector<std::string> lines;
    std::string error;
    {
        std::lock_guard<std::mutex> lk(state.mtx);
        lines = state.fastfetchLines;
        error = state.fastfetchError;
    }
    if (lines.empty() && !error.empty()) {
        centerMessage(out, x, y, w, h, error, BOLD + fg(220, 50, 50), border);
        return;
    }
    if (lines.empty()) {
        centerMessage(out, x, y, w, h, "Loading fetch info...", DIM + ITALIC, border);
        return;
    }
    int maxRows = h - 2;
    for (int i = 0; i < (int)lines.size() && i < maxRows; i++)
        drawContentLine(out, x, y, w, h, i, lines[i], border);
}

static void buildNowPlayingPanel(std::string &out, AppState &state, int x, int y, int w, int h) {
    const std::string border = fg(200, 0, 200);
    drawPanelFrame(out, x, y, w, h, BOLD + fg(220, 0, 220) + "now playing" + RESET, border);

    NowPlaying np;
    {
        std::lock_guard<std::mutex> lk(state.mtx);
        np = state.nowPlaying;
    }
    if (!np.fatal.empty()) {
        centerMessage(out, x, y, w, h, np.fatal, BOLD + fg(220, 50, 50), border);
        return;
    }
    if (!np.available) {
        centerMessage(out, x, y, w, h, "\u266A  nothing playing  \u266A", DIM + ITALIC, border);
        return;
    }

    int row = 0;
    std::string header = BOLD + fg(0, 220, 100) + std::string(STATUS_ICON(np.status)) + " " +
                          RESET + fg(120, 120, 120) + BOLD + np.player + RESET;
    drawContentLine(out, x, y, w, h, row++, header, border);
    row++;
    drawContentLine(out, x, y, w, h, row++, BOLD + fg(255, 255, 255) + np.title + RESET, border);
    drawContentLine(out, x, y, w, h, row++, ITALIC + fg(0, 200, 200) + np.artist + RESET, border);
    if (!np.album.empty())
        drawContentLine(out, x, y, w, h, row++, DIM + np.album + RESET, border);
    row++;

    int barWidth = std::max(4, w - 6);
    int filled = (int)(np.ratio * barWidth);
    std::string barStr = fg(200, 0, 200);
    for (int i = 0; i < filled; i++) barStr += "\u2588";
    barStr += fg(90, 90, 90);
    for (int i = 0; i < barWidth - filled; i++) barStr += "\u2591";
    barStr += RESET;
    drawContentLine(out, x, y, w, h, row++, barStr, border);
    drawContentLine(out, x, y, w, h, row++, DIM + np.posStr + " / " + np.lenStr + RESET, border);
}

static void buildVisualizerPanel(std::string &out, AppState &state, int x, int y, int w, int h) {
    const std::string border = fg(220, 0, 220);
    drawPanelFrame(out, x, y, w, h, BOLD + fg(230, 0, 230) + "visualizer" + RESET, border);

    std::vector<int> values;
    std::string error;
    {
        std::lock_guard<std::mutex> lk(state.mtx);
        values = state.bars;
        error = state.cavaError;
    }
    if (values.empty() && !error.empty()) {
        centerMessage(out, x, y, w, h, error, BOLD + fg(220, 50, 50), border);
        return;
    }
    if (values.empty()) {
        centerMessage(out, x, y, w, h, "Waiting for audio...", DIM + ITALIC, border);
        return;
    }

    int contentH = h - 2;
    int contentW = w - 4;
    int maxRange = contentH * 8;
    static const char *BLOCKS[9] = {" ", "\u2581", "\u2582", "\u2583", "\u2584",
                                    "\u2585", "\u2586", "\u2587", "\u2588"};
    int n = std::min((int)values.size(), contentW);
    for (int rowFromTop = 0; rowFromTop < contentH; rowFromTop++) {
        int rowFromBottom = contentH - 1 - rowFromTop;
        int thresholdMin = rowFromBottom * 8;
        int gradIdx = std::min(rowFromBottom, 7);
        std::string rowStr = fg(VU_GRADIENT[gradIdx][0], VU_GRADIENT[gradIdx][1],
                                 VU_GRADIENT[gradIdx][2]);
        for (int i = 0; i < n; i++) {
            int v = std::max(0, std::min(maxRange, values[i]));
            int fill = v - thresholdMin;
            if (fill >= 8) rowStr += BLOCKS[8];
            else if (fill <= 0) rowStr += " ";
            else rowStr += BLOCKS[fill];
        }
        rowStr += RESET;
        drawContentLine(out, x, y, w, h, rowFromTop, rowStr, border);
    }
}

static std::atomic<bool> g_stop{false};
static std::atomic<bool> g_resizePending{false};
static AppState *g_state = nullptr;

static void handleSignal(int sig) {
    if (sig == SIGWINCH) {
        g_resizePending.store(true);
        return;
    }
    g_stop.store(true);
    if (g_state) {
        g_state->stop.store(true);
        pid_t p = g_state->cavaPid.load();
        if (p > 0) kill(p, SIGTERM);
    }
}

static void printUsage(const char *prog) {
    printf("Usage: %s [options]\n"
           "  --fetch-backend <fastfetch|hyfetch|neofetch>  (default fastfetch)\n"
           "  --fastfetch-interval <seconds>   (default 3.0)\n"
           "  --player-interval <seconds>      (default 1.0)\n"
           "  --fps <n>                        (default 20)\n"
           "  --bars <n>                       (default 106)\n"
           "  --player <name>                  restrict playerctl to a player\n"
           "  --fastfetch-args \"<args>\"         extra args passed to the backend\n"
           "  -h, --help\n",
           prog);
}

int main(int argc, char **argv) {
    std::string backend = "fastfetch";
    double fastfetchInterval = 3.0;
    double playerInterval = 1.0;
    double fps = 20.0;
    int bars = 106;
    int visHeightCfg = 8;
    std::string player;
    std::string fastfetchArgsRaw;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&](const char *name) -> std::string {
            if (i + 1 >= argc) { fprintf(stderr, "%s requires a value\n", name); exit(1); }
            return argv[++i];
        };
        if (a == "--fetch-backend") backend = next("--fetch-backend");
        else if (a == "--fastfetch-interval") fastfetchInterval = std::stod(next("--fastfetch-interval"));
        else if (a == "--player-interval") playerInterval = std::stod(next("--player-interval"));
        else if (a == "--fps") fps = std::stod(next("--fps"));
        else if (a == "--bars") bars = std::stoi(next("--bars"));
        else if (a == "--vis-height") visHeightCfg = std::stoi(next("--vis-height"));
        else if (a == "--player") player = next("--player");
        else if (a == "--fastfetch-args") fastfetchArgsRaw = next("--fastfetch-args");
        else if (a == "-h" || a == "--help") { printUsage(argv[0]); return 0; }
        else { fprintf(stderr, "Unknown option: %s\n", a.c_str()); printUsage(argv[0]); return 1; }
    }

    if (const char *envBackend = getenv("BEATFETCH_FETCH_BACKEND")) {
        if (backend == "fastfetch") backend = envBackend;
    }

    if (backend != "fastfetch" && backend != "hyfetch" && backend != "neofetch") {
        fprintf(stderr, "Error: unsupported fetch backend '%s'.\n", backend.c_str());
        return 1;
    }
    if (!backendAvailable(backend)) {
        fprintf(stderr, "Error: '%s' was not found on PATH.\n", backend.c_str());
        return 1;
    }
    if (!commandExists("playerctl"))
        fprintf(stderr, "Warning: 'playerctl' not found - now-playing panel disabled.\n");
    if (!commandExists("cava"))
        fprintf(stderr, "Warning: 'cava' not found - visualizer panel disabled.\n");

    std::vector<std::string> extraArgs;
    if (!fastfetchArgsRaw.empty()) {
        std::istringstream iss(fastfetchArgsRaw);
        std::string tok;
        while (iss >> tok) extraArgs.push_back(tok);
    }

    AppState state;
    g_state = &state;
    signal(SIGINT, handleSignal);
    signal(SIGTERM, handleSignal);
    signal(SIGWINCH, handleSignal);

    std::thread tFastfetch(fastfetchWorker, std::ref(state), fastfetchInterval, backend, extraArgs);
    std::thread tPlayer(nowPlayingWorker, std::ref(state), playerInterval, player);
    std::thread tCava(cavaWorker, std::ref(state), bars, visHeightCfg);

    printf("\033[?1049h\033[?25l\033[?7l");
    fflush(stdout);

    auto frameDelay = std::chrono::milliseconds((long)(1000.0 / std::max(1.0, fps)));
    while (!g_stop.load()) {
        int cols, rows;
        getTermSize(cols, rows);

        std::string frame;
        frame += "\033[2J\033[H";

        if (cols >= 100) {
            int leftW = std::max(30, (cols * 3) / 5);
            int rightX = leftW + 1;
            int rightW = cols - rightX + 1;
            if (rightW < 24) rightW = 24;
            if (rightX > cols) rightX = cols;

            int nowPlayingH = std::min(12, std::max(6, rows - 4));
            int visY = 1 + nowPlayingH;
            int visH = rows - nowPlayingH;
            if (visH < 4) visH = 4;

            buildFastfetchPanel(frame, state, 1, 1, leftW, rows);
            buildNowPlayingPanel(frame, state, rightX, 1, rightW, nowPlayingH);
            buildVisualizerPanel(frame, state, rightX, visY, rightW, visH);
        } else {
            int systemH = std::max(8, rows / 3);
            int nowPlayingH = std::max(6, (rows - systemH) / 2);
            int visH = rows - systemH - nowPlayingH;
            if (visH < 4) {
                visH = 4;
                nowPlayingH = std::max(6, rows - systemH - visH);
            }
            if (nowPlayingH < 4) nowPlayingH = 4;
            buildFastfetchPanel(frame, state, 1, 1, cols, systemH);
            buildNowPlayingPanel(frame, state, 1, 1 + systemH, cols, nowPlayingH);
            buildVisualizerPanel(frame, state, 1, 1 + systemH + nowPlayingH, cols, visH);
        }

        ssize_t wr = write(STDOUT_FILENO, frame.data(), frame.size());
        (void)wr;

        g_resizePending.store(false);
        std::this_thread::sleep_for(frameDelay);
    }

    printf("\033[?7h\033[?25h\033[?1049l");
    fflush(stdout);

    state.stop.store(true);
    {
        pid_t p = state.cavaPid.load();
        if (p > 0) kill(p, SIGTERM);
    }
    tFastfetch.join();
    tPlayer.join();
    tCava.join();
    return 0;
}
