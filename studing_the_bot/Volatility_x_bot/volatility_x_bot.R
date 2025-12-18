#---------------------------------------------------------
# USAGE: You must move this document into a folder where 
# you have all documents you used for the testbench.
# I recommend you to make a folder with a softlink to each 
# document and also this code.
# !!! The algorithm to study was ment to a data base where 
# each stock and year has 12 documents: 1 per month
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
summary_file <- "saved_data_no_outlayers.csv" 

if (!file.exists(summary_file)) stop(paste("ERROR: File not found:", summary_file))

# ---------------------------------------------------------
# 2. Data Processing Function
# ---------------------------------------------------------
process_volatility <- function() {
  
  # Search for all Oanda CSV files in the current directory
  # Note: Adjust path if files are located in a subdirectory
  files <- list.files(pattern = "^oanda-.*\\.csv$") # This pattern is from the data base I used to try my bot.
  
  if(length(files) == 0) stop("No 'oanda-*.csv' files found in the directory.")
  
  cat("Found", length(files), "price files. Filtering and calculating...\n")
  
  results_list <- list()
  
  for (f in files) {
    # Extract metadata from filename (e.g., oanda-NAS100_USD-2005-1.csv)
    file_name <- basename(f)
    parts <- str_split(file_name, "-")[[1]]
    
    if (length(parts) < 3) next 
    
    stock_raw <- parts[2] # e.g., "NAS100_USD"
    year_raw <- parts[3]  # e.g., "2005"
    
    # Filter: Exclude Bitcoin (BTC) from analysis
    if (grepl("BTC", stock_raw)) {
      next
    }
    
    # Standardize stock name to match summary file (NAS100_USD -> NAS100)
    stock_clean <- str_replace(stock_raw, "_USD", "")
    
    # Read file and calculate volatility
    tryCatch({
      # Load only the 'close' column for performance
      df <- read_csv(f, col_types = cols_only(close = col_double()), show_col_types = FALSE)
      
      # Calculate Volatility: Sum of absolute percentage changes
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
  
  if (length(results_list) == 0) stop("No valid data processed (check if files exist or only contain BTC).")

  all_partials <- do.call(rbind, results_list)
  
  # Aggregate monthly data into annual totals
  final_index <- all_partials %>%
    group_by(stock, year) %>%
    summarise(volatility_index = sum(partial_vol), .groups = 'drop') %>%
    arrange(stock, year)
  
  return(final_index)
}

# ---------------------------------------------------------
# 3. Execution & Verification
# ---------------------------------------------------------

# A. Calculation
cat("Calculating volatility (Excluding BTC)...\n")
vol_index <- process_volatility()

# B. Output results to console
cat("\n=================================================\n")
cat(" CALCULATED ANNUAL VOLATILITY INDEX\n")
cat(" (Sum of all price movements within the year)\n")
cat("=================================================\n")
print(as.data.frame(vol_index))
cat("=================================================\n\n")

# C. Load bot performance data
bot_data <- read.csv(summary_file)

# D. Merge datasets
# Inner join ensures only matching Stock+Year combinations are kept
merged_data <- inner_join(bot_data, vol_index, by = c("stock", "year"))

cat("DATA MERGE VERIFICATION:\n")
cat("Rows in summary file:", nrow(bot_data), "\n")
cat("Years of volatility calculated:", nrow(vol_index), "\n")
cat("Successfully merged rows:", nrow(merged_data), "\n\n")

if (nrow(merged_data) == 0) {
  stop("CRITICAL ERROR: No matching rows found. Please check if Stock names match (e.g., 'NAS100' vs 'NAS100_USD').")
} else {
  cat("CONFIRMATION: Successfully matched", nrow(merged_data), "years of data.\n")
  cat("Sample of merged data:\n")
  print(head(merged_data[, c("stock", "year", "roi_bot", "volatility_index")]))
}

# ---------------------------------------------------------
# 4. Correlation Analysis & Plotting
# ---------------------------------------------------------
merged_data$alpha <- merged_data$roi_bot - merged_data$roi_std

if (nrow(merged_data) >= 3) {
  
  # Perform correlation test
  cor_test <- cor.test(merged_data$volatility_index, merged_data$alpha)
  
  cat("\n--- FINAL RESULTS ---\n")
  cat("Correlation Coefficient (R):", round(cor_test$estimate, 4), "\n")
  cat("P-Value:", format.pval(cor_test$p.value), "\n")
  
  # Generate Plot
  p <- ggplot(merged_data, aes(x = volatility_index, y = alpha)) +
    geom_point(aes(color = stock), size = 3) +
    geom_smooth(method = "lm", se = FALSE, color = "black", linetype = "dashed") +
    labs(
      title = "Bot Alpha vs Annual Volatility (No BTC)",
      subtitle = paste("R =", round(cor_test$estimate, 3)),
      x = "Total Volatility Index",
      y = "Bot Alpha (ROI Bot - ROI Std)"
    ) +
    theme_minimal()
  
  ggsave("volatility_analysis.png", plot = p, width = 8, height = 6)
  cat("Plot saved as 'volatility_analysis.png'\n")
  
} else {
  cat("WARNING: Not enough data points to calculate correlation (< 3 years).\n")
}
