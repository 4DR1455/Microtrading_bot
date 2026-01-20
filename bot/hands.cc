#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <sstream>
#include <thread>
#include <mutex>
#include <iomanip>
#include <unistd.h>      
#include <sys/wait.h>    
#include <cstring>
#include <signal.h>
#include <thread>

const float I_BUDGET = 1000000.0;
const std::string BRAIN_EXEC = "./brain"; 

std::mutex data_mutex;
std::fstream data_file;

// --- UTILS ---

// Safe function to read a complete line from a Pipe (char by char)
// This prevents reading half an order or two orders together
std::string readline_pipe(int fd) {
    std::string line;
    char c;
    while (true) {
        int n = read(fd, &c, 1);
        if (n <= 0) break; // Error or Pipe closed
        if (c == '\n') break;
        line += c;
    }
    return line;
}

struct AmericanFormat : std::numpunct<char> {
    char do_thousands_sep() const override { return ','; } 
    char do_decimal_point() const override { return '.'; }
    std::string do_grouping() const override { return "\003"; } 
};

std::string get_info(const std::string& filepath) {
    size_t last_slash = filepath.find_last_of("/\\");
    size_t last_dot = filepath.find_last_of('-');
    if (last_slash == std::string::npos) last_slash = -1;
    if (last_dot == std::string::npos || last_dot < last_slash) last_dot = filepath.length();
    return filepath.substr(last_slash + 1, last_dot - last_slash - 1);
}

void sumry(float initial_budget, float price, int shares, float f_price, std::string filename, float current_budget) {
    float current_welth = current_budget + price * shares;
    float roi = ((current_welth - initial_budget) / initial_budget) * 100;
    float no_bot_roi = (((price - f_price) / f_price) * 100);

    std::lock_guard<std::mutex> lock(data_mutex);
    if (data_file.is_open()) {
        std::string stock_year = get_info(filename);
        std::cout << "[Summary] File: " << stock_year << " | ROI Bot: " << std::setprecision(6) << roi << "% | ROI Std: " << no_bot_roi << "% | Diff: " << (roi - no_bot_roi) << "%" << std::endl;
        data_file << std::setprecision(6) << stock_year << ',' << roi << ',' << no_bot_roi << ',' << roi - no_bot_roi << std::endl;
    }
}

double extract_open_price(const std::string& line) {
    std::stringstream ss(line);
    std::string segment;
    std::vector<std::string> seglist;
    while(std::getline(ss, segment, ',')) seglist.push_back(segment);
    if (seglist.size() < 5) return 0.0;
    try { return std::stod(seglist[1]); } catch (...) { return 0.0; }
}

double extract_close_price(const std::string& line) {
    std::stringstream ss(line);
    std::string segment;
    std::vector<std::string> seglist;
    while(std::getline(ss, segment, ',')) seglist.push_back(segment);
    if (seglist.size() < 5) return 0.0;
    try { return std::stod(seglist[4]); } catch (...) { return 0.0; }
}

int parse_quantity(const std::string& order) {
    try {
        size_t space_pos = order.find(' ');
        if (space_pos != std::string::npos) return std::stoi(order.substr(space_pos + 1));
        return 1; 
    } catch (...) { return 0; }
}
// ... ---------------------------------------------------------------------------------------- ...

void listen_to_brain(int fd_read, float& current_budget, int& shares_owned, double current_price, std::thread::id index) {
    
    // USE SAFE READING
    std::string order = readline_pipe(fd_read);
    
    if (order.empty()) return;

    // Remove \r if present (sometimes implies windows encoded pipes)
    if (!order.empty() && order.back() == '\r') order.pop_back();

    if (order.find("BUY") == 0) {
        int qty = parse_quantity(order);
        double cost = (current_price * qty) * 1; 
        if (current_budget >= cost) {
            current_budget -= cost; 
            shares_owned += qty;
        }
    } 
    else if (order.find("SELL") == 0) {
        int qty = parse_quantity(order);
        if (shares_owned >= qty) {
            double revenue = current_price * qty;
            current_budget += revenue;
            shares_owned -= qty;
        }
    } 
}

// The hands algorithm itself
void* data_feed(void * arg) {
    std::vector<std::string> *filenames = static_cast<std::vector<std::string>*>(arg);

    int pipe_to_brain[2];
    int pipe_from_brain[2];

    if (pipe(pipe_to_brain) < 0 || pipe(pipe_from_brain) < 0) {
        perror("Pipe error");
        pthread_exit(nullptr);
    }

    pid_t pid = fork();
    if (pid < 0) {
        perror("Fork error");
        pthread_exit(nullptr);
    }

    if (pid == 0) { // CHILD
        close(pipe_to_brain[1]);
        close(pipe_from_brain[0]);
        dup2(pipe_to_brain[0], STDIN_FILENO);
        dup2(pipe_from_brain[1], STDOUT_FILENO);
        close(pipe_to_brain[0]);
        close(pipe_from_brain[1]);

        execlp(BRAIN_EXEC.c_str(), "brain", nullptr);
        perror("Exec failed (Check if ./brain exists!)"); // Error message if fails
        exit(1);
    }

    // PARENT
    close(pipe_to_brain[0]);
    close(pipe_from_brain[1]);

    float current_budget = I_BUDGET;
    int shares_owned = 0;
    double last_known_price = 0.0;
    float l_price = 0.0;
    float f_price = 0.0;
    bool first = true;

    for (const auto& doc : *filenames) {
        std::ifstream file(doc);
        if (!file.is_open()) {
            std::lock_guard<std::mutex> lock(data_mutex);
            std::cerr << "[Error] Cannot open: " << doc << std::endl;
            continue;
        }

        std::string line;
        std::getline(file, line); 

        while (std::getline(file, line)) {
            double price = extract_open_price(line);
            if (first) { f_price = price; first = false; }

            // Only send if the price is valid
            if (price > 0.0) {
                last_known_price = price;
                std::string msg = std::to_string(current_budget) + ";" + std::to_string(price) + ";" + std::to_string(shares_owned) + "\n";
                
                // Ignore SIGPIPE in case the brain process has died
                if (write(pipe_to_brain[1], msg.c_str(), msg.size()) == -1) break;
                
                listen_to_brain(pipe_from_brain[0], current_budget, shares_owned, last_known_price, std::this_thread::get_id());
            }

            price = extract_close_price(line);
            if (price > 0.0) {
                last_known_price = price;
                std::string msg = std::to_string(current_budget) + ";" + std::to_string(price) + ";" + std::to_string(shares_owned) + "\n";
                
                if (write(pipe_to_brain[1], msg.c_str(), msg.size()) == -1) break;

                listen_to_brain(pipe_from_brain[0], current_budget, shares_owned, last_known_price, std::this_thread::get_id());
            }
            l_price = price;
        }
        file.close();
    }
    std::cout << "End of data feed for PID " << pid << std::endl;

    close(pipe_to_brain[1]);
    close(pipe_from_brain[0]);
    
    sumry(I_BUDGET, l_price, shares_owned, f_price, filenames->front(), current_budget);
    
    kill(pid, SIGKILL);
    waitpid(pid, nullptr, 0);

    pthread_exit(nullptr);
}

// Multithreading system
int main() {
    // IMPORTANT: Ignore pipe break signal to prevent global crash
    signal(SIGPIPE, SIG_IGN);

    data_file.open("data.csv", std::ios::out);
    data_file << "filename,roi_bot,roi_std,bot-std" << std::endl;

    std::locale american_locale(std::locale(), new AmericanFormat());
    std::cerr.imbue(american_locale);

    // Data Source
    std::vector<std::vector<std::string>> data_set = {
        // Here you insert a vector for each year fo trading an example of my case:
        //{
        //    "../../DB2/archive/pyfinancialdata/data/currencies/oanda/NAS100_USD/2005/oanda-NAS100_USD-2005-1.csv",
        //    "../../DB2/archive/pyfinancialdata/data/currencies/oanda/NAS100_USD/2005/oanda-NAS100_USD-2005-2.csv",
        //    "../../DB2/archive/pyfinancialdata/data/currencies/oanda/NAS100_USD/2005/oanda-NAS100_USD-2005-3.csv",
        //    "../../DB2/archive/pyfinancialdata/data/currencies/oanda/NAS100_USD/2005/oanda-NAS100_USD-2005-4.csv",
        //    "../../DB2/archive/pyfinancialdata/data/currencies/oanda/NAS100_USD/2005/oanda-NAS100_USD-2005-5.csv",
        //    "../../DB2/archive/pyfinancialdata/data/currencies/oanda/NAS100_USD/2005/oanda-NAS100_USD-2005-6.csv",
        //    "../../DB2/archive/pyfinancialdata/data/currencies/oanda/NAS100_USD/2005/oanda-NAS100_USD-2005-7.csv",
        //    "../../DB2/archive/pyfinancialdata/data/currencies/oanda/NAS100_USD/2005/oanda-NAS100_USD-2005-8.csv",
        //    "../../DB2/archive/pyfinancialdata/data/currencies/oanda/NAS100_USD/2005/oanda-NAS100_USD-2005-9.csv",
        //    "../../DB2/archive/pyfinancialdata/data/currencies/oanda/NAS100_USD/2005/oanda-NAS100_USD-2005-10.csv",
        //    "../../DB2/archive/pyfinancialdata/data/currencies/oanda/NAS100_USD/2005/oanda-NAS100_USD-2005-11.csv",
        //    "../../DB2/archive/pyfinancialdata/data/currencies/oanda/NAS100_USD/2005/oanda-NAS100_USD-2005-12.csv"
        //}, ...
    };

    // Simple error check
    if (data_set.empty()) {
        std::cerr << "Dataset empty! Check the code." << std::endl;
        return 1;
    }

    std::vector<pthread_t> thread_ids(data_set.size());
    size_t n_threads = 10; 
    
    std::cout << "Starting simulation with " << data_set.size() << " elements (" << n_threads << " concurrent)..." << std::endl;

    // --- CORRECTED LOOP: BATCHES WITHOUT DOUBLE JOIN ---
    
    size_t total_tasks = data_set.size();
    
    for (size_t i = 0; i < total_tasks; i += n_threads) {
        size_t tasks_in_this_batch = 0;

        // 1. CREATE BATCH (Respecting vector limits)
        for (size_t j = 0; j < n_threads; j++) {
            size_t current_idx = i + j;
            if (current_idx < total_tasks) {
                int ret = pthread_create(&thread_ids[current_idx], nullptr, data_feed, (void*)&data_set[current_idx]);
                if (ret != 0) {
                    std::cerr << "Error creating thread " << current_idx << std::endl;
                    exit(-1);
                }
                tasks_in_this_batch++;
            }
        }

        // 2. WAIT FOR BATCH (JOIN)
        // We only wait for the ones we just created.
        for (size_t j = 0; j < tasks_in_this_batch; j++) {
            size_t current_idx = i + j;
            pthread_join(thread_ids[current_idx], nullptr);
        }
        
        std::cout << "\n[Batch finished: " << (i + tasks_in_this_batch) << "/" << total_tasks << "]" << std::endl;
    }

    data_file.close();
    std::cout << "Simulation finished." << std::endl;
    return 0;
}
