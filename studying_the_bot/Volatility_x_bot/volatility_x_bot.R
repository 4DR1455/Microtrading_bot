#---------------------------------------------------------
# USAGE: Move this file into the folder containing your 
# testbench results. Ensure 'saved_data.csv' and all 
# 'oanda-*.csv' price files are present.
#---------------------------------------------------------

# ---------------------------------------------------------
# 1. Configuration & Libraries
# ---------------------------------------------------------
if (!require("dplyr")) install.packages("dplyr")
if (!require("readr")) install.packages("readr")
if (!require("stringr")) install.packages("stringr")
if (!require("ggplot2")) library(ggplot2)

library(dplyr)
library(readr)
library(stringr)
library(ggplot2)

# File containing the bot's annual performance
summary_file <- "saved_data.csv" 

if (!file.exists(summary_file)) stop(paste("ERROR: File not found:", summary_file))

# ---------------------------------------------------------
# 2. Load and Filter Reference Data
# ---------------------------------------------------------
# Load summary data to identify valid years based on ROI thresholds
bot_data_raw <- read.csv(summary_file)

cat("Total rows in summary file:", nrow(bot_data_raw), "\n")

# --- ANTI-OUTLIER FILTER ---
# Exclude any year where Bot or Standard Market ROI is > 200%
bot_data_filtered <- bot_data_raw[
  bot_data_raw$roi_bot < 200 & 
  bot_data_raw$roi_std < 200, 
]

cat("Rows after removing Outliers (>200% ROI):", nrow(bot_data_filtered), "\n")
cat("-------------------------------------------------\n")

# ---------------------------------------------------------
# 3. Data Processing Function
# ---------------------------------------------------------
process_volatility <- function(valid_data) {
  
  # Search for Oanda CSV files
  files <- list.files(pattern = "^oanda-.*\\.csv$") 
  
  if(length(files) == 0) stop("No 'oanda-*.csv' files found.")
  
  cat("Found", length(files), "price files. Checking against filter list...\n")
  
  results_list <- list()
  
  # Create a lookup key "STOCK_YEAR" for valid entries
  allowed_keys <- paste(valid_data$stock, valid_data$year, sep = "_")
  
  for (f in files) {
    # Extract metadata from filename
    file_name <- basename(f)
    parts <- str_split(file_name, "-")[[1]]
    
    if (length(parts) < 3) next 
    
    stock_raw <- parts[2] 
    year_raw <- parts[3]  
    
    # Standardize stock name
    stock_clean <- str_replace(stock_raw, "_USD", "")
    
    # --- FILTER CHECK ---
    # Only process files that exist in the filtered summary list
    current_key <- paste(stock_clean, year_raw, sep = "_")
    
    if (!(current_key %in% allowed_keys)) {
      next 
    }
    
    # Read file and calculate volatility
    tryCatch({
      df <- read_csv(f, col_types = cols_only(close = col_double()), show_col_types = FALSE)
      
      # Volatility = Sum of absolute percentage changes
      pct_changes <- abs(diff(df$close) / head(df$close, -1))
      partial_vol <- sum(pct_changes, na.rm = TRUE) * 100
      
      results_list[[f]] <- data.frame(
        stock = stock_clean,
        year = as.integer(year_raw),
        partial_vol = partial_vol
      )
    }, error = function(e) {
      cat("Error reading file", f, ":", e$message, "\n")
    })
  }
  
  if (length(results_list) == 0) stop("No valid data processed.")

  all_partials <- do.call(rbind, results_list)
  
  # Aggregate monthly data into annual totals
  final_index <- all_partials %>%
    group_by(stock, year) %>%
    summarise(volatility_index = sum(partial_vol), .groups = 'drop') %>%
    arrange(stock, year)
  
  return(final_index)
}

# ---------------------------------------------------------
# 4. Execution & Verification
# ---------------------------------------------------------

# A. Calculation
cat("Calculating volatility for valid years...\n")
vol_index <- process_volatility(bot_data_filtered)

# B. Output results
cat("\n=================================================\n")
cat(" CALCULATED ANNUAL VOLATILITY INDEX\n")
cat("=================================================\n")
print(as.data.frame(vol_index))
cat("=================================================\n\n")

# C. Merge datasets
merged_data <- inner_join(bot_data_filtered, vol_index, by = c("stock", "year"))

cat("DATA MERGE VERIFICATION:\n")
cat("Valid rows in summary:", nrow(bot_data_filtered), "\n")
cat("Years calculated:", nrow(vol_index), "\n")
cat("Merged rows:", nrow(merged_data), "\n\n")

if (nrow(merged_data) == 0) {
  stop("CRITICAL ERROR: No matching rows found.")
} else {
  cat("CONFIRMATION: Successfully matched", nrow(merged_data), "years of data.\n")
  print(head(merged_data[, c("stock", "year", "roi_bot", "volatility_index")]))
}

# ---------------------------------------------------------
# 5. Correlation Analysis & Plotting
# ---------------------------------------------------------
merged_data$alpha <- merged_data$roi_bot - merged_data$roi_std

if (nrow(merged_data) >= 3) {
  
  cor_test <- cor.test(merged_data$volatility_index, merged_data$alpha)
  
  cat("\n--- FINAL RESULTS ---\n")
  cat("Correlation Coefficient (R):", round(cor_test$estimate, 4), "\n")
  cat("P-Value:", format.pval(cor_test$p.value), "\n")
  
  # Generate Plot
  p <- ggplot(merged_data, aes(x = volatility_index, y = alpha)) +
    geom_point(aes(color = stock), size = 3) +
    geom_smooth(method = "lm", se = FALSE, color = "black", linetype = "dashed") +
    labs(
      title = "Bot Alpha vs Annual Volatility (Outliers removed)",
      subtitle = paste("R =", round(cor_test$estimate, 3), "| ROI > 200% excluded"),
      x = "Total Volatility Index",
      y = "Bot Alpha (ROI Bot - ROI Std)"
    ) +
    theme_minimal()
  
  ggsave("volatility_analysis.png", plot = p, width = 8, height = 6)
  cat("Plot saved as 'volatility_analysis.png'\n")
  
} else {
  cat("WARNING: Not enough data points to calculate correlation (< 3 years).\n")
}
