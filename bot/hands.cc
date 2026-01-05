#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <sstream>
#include <thread>
#include <chrono>
#include <atomic>
#include <iomanip>
#include <fstream>

const float I_BUDGET = 1000000.0;

// --- FORMATTING CONFIGURATION ---
// Custom facet to force American number formatting (1,000.00)
struct AmericanFormat : std::numpunct<char> {
    char do_thousands_sep() const override { return ','; } 
    char do_decimal_point() const override { return '.'; }
    std::string do_grouping() const override { return "\003"; } // Groups of 3 digits
};

// --- SHARED STATE ---
// Atomic variables to ensure thread safety between Data Feed and Listener threads.
std::atomic<double> current_budget(I_BUDGET); // Initial Capital
std::atomic<int> shares_owned(0);
std::atomic<double> last_known_price(0.0);
std::fstream data = std::fstream("../studing_the_bot/data.csv");
char sep = ',';
std::ifstream return_channel("trading_pipe");

// --- UTILITIES ---

//Helper: Sumarizes a trading session.
void sumry(float initial_budget, float price, int shares, float f_price) {
    float current_welth = current_budget + price * shares;
    float bot_roi = ((current_welth - initial_budget) / initial_budget) * 100;

    //std::cerr << std::endl << "ROI = " << std::setprecision(5) << std::fixed << bot_roi << '%' << std::endl;
    //std::cerr << "  Initial budget = " << std::setprecision(2) << std::fixed << initial_budget << "€" << std::endl;
    //std::cerr << "  Final budget = " << std::setprecision(2) << std::fixed << current_welth << "€" << std::endl;

    float std_roi = (((price - f_price) / f_price) * 100);

    data << std::setprecision(6) << bot_roi << ',' << std_roi << ',' << bot_roi - std_roi << std::endl;
}


// Helper: Extract 'Open' Price from CSV line (Column 2, Index 1)
double extract_open_price(const std::string& line) {
    std::stringstream ss(line);
    std::string segment;
    std::vector<std::string> seglist;
    while(std::getline(ss, segment, sep)) { // Assuming comma-separated CSV
        seglist.push_back(segment);
    }
    // Ensure row has enough columns
    if (seglist.size() < 5) return 0.0;
    try { return std::stod(seglist[1]); } catch (...) { return 0.0; }
}

// Helper: Extract 'Close' Price from CSV line (Column 5, Index 4)
double extract_close_price(const std::string& line) {
    std::stringstream ss(line);
    std::string segment;
    std::vector<std::string> seglist;
    while(std::getline(ss, segment, sep)) { // Assuming comma-separated CSV
        seglist.push_back(segment);
    }
    // Ensure row has enough columns
    if (seglist.size() < 5) return 0.0;
    try { return std::stod(seglist[4]); } catch (...) { return 0.0; }
}

// Helper: Parse quantity from order string (e.g., "BUY 10" -> 10)
int parse_quantity(const std::string& order) {
    try {
        size_t space_pos = order.find(' ');
        if (space_pos != std::string::npos) {
            return std::stoi(order.substr(space_pos + 1));
        }
        return 1; // Default to 1 if no quantity specified
    } catch (...) {
        return 0;
    }
}

// --- LISTENER THREAD ---
// Listens for commands coming from the Brain (OCaml) via named pipe.
void listen_to_brain() {

    std::string order;
    std::getline(return_channel, order);
    std::atomic<double> price = last_known_price.load();
    
    // --- EXECUTE BUY ---
    if (order.find("BUY") == 0) {
        int qty = parse_quantity(order);
        double cost = (price * qty);
        if (current_budget >= cost) {
            current_budget = current_budget - cost; 
            shares_owned += qty;
            
            //std::cerr << std::endl << " >>> [EXEC] BOUGHT " << qty << " @ " << std::fixed << std::setprecision(2) << price.load() 
            //          << "€ | Shares: " << std::fixed << std::setprecision(2) << shares_owned.load() 
            //          << " | Budget: " << std::fixed << std::setprecision(2) << current_budget.load()
            //          << "€" << std::flush;
        } else {
            //std::cerr << std::endl << " >>> [REJECT] Insufficient funds for BUY." << std::flush;
        }
    } 
    // --- EXECUTE SELL ---
    else if (order.find("SELL") == 0) {
        int qty = parse_quantity(order);
        
        if (shares_owned >= qty) {
            double revenue = price * qty;
            current_budget = current_budget + revenue;
            shares_owned -= qty;
            
            //std::cerr << std::endl << " >>> [EXEC] SOLD   " << qty << " @ " << std::fixed << std::setprecision(2) << price.load() 
            //          << "€ | Shares: " << std::fixed << std::setprecision(2) << shares_owned.load() 
            //          << " | Budget: " << std::fixed << std::setprecision(2) << current_budget.load()
            //          << "€" << std::flush;
        } else {
            //std::cerr << std::endl << " >>> [REJECT] Insuficient shares to sell: Trying to sell " << qty << " but have " << shares_owned << std::flush;
        }
    } 
    // --- HOLD ---
    else {
        //std::cerr << "·" << std::flush;
    }
}

// --- MAIN THREAD ---
// Reads CSV data and streams simulation state to the Brain.
int main() {

    if (!return_channel.is_open()) {
        std::cerr << std::endl << "[HANDS-Error] Could not open 'trading_pipe'. Run: mkfifo trading_pipe";
        return 1;
    }

    data << "roi_bot,roi_std,diff," << std::endl;

    // Apply formatting to Error Stream (Console output)
    std::locale american_locale(std::locale(), new AmericanFormat());
    std::cerr.imbue(american_locale);

    // Data Source
    std::vector<std::vector<std::string>> data_set = {{"Path to data base of year 1"},{"Path to data base of year 2"},/*...*/};

    std::string line;

    bool first = true;
    bool day_change;

    float l_price;
    float f_price;

    // Simulation Loop
    for (auto filenames : data_set) {
        first = true;
        shares_owned = 0;
        current_budget = I_BUDGET;
        for (auto doc : filenames) {
            std::ifstream file(doc);

            if (!file.is_open()) {
                std::cerr << "[Error] Could not open data file: " << doc << std::endl;
                return 1;
            }
            std::getline(file, line); // Skip header
            while (std::getline(file, line)) {

                double price = extract_open_price(line);

                if (first) {
                    f_price = price;
                    first = false;
                }
            
                if (price > 0.0) {
                    last_known_price.store(price);
                
                    // SEND STATE: Budget;Price;TotalShares
                    // Sends raw data to OCaml (no fancy formatting to ease parsing)
                    std::cout << current_budget.load() << ";" 
                              << price << ";" 
                              << shares_owned.load() << std::endl;
                
                    listen_to_brain();
                }
            
                price = extract_close_price(line);
                if (price > 0.0) {
                    last_known_price.store(price);
                
                    // SEND STATE: Budget;Price;TotalShares
                    // Sends raw data to OCaml (no fancy formatting to ease parsing)
                    std::cout << current_budget.load() << ";" 
                              << price << ";" 
                              << shares_owned.load() << std::endl;
                
                    listen_to_brain();
                }
                l_price = price;
                std::cerr << std::fixed << std::setprecision(2) << current_budget + shares_owned * price << "€ " << std::endl;
            }
            
        }
        sumry(I_BUDGET, l_price, shares_owned, f_price);
        std::cerr << std::endl << "--------------------------------------------" << std::endl;
    }
    return 0;
}
