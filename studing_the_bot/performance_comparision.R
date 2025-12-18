# ---------------------------------------------------------
# 1. Configuration & Libraries
# ---------------------------------------------------------
if (!require("ggplot2")) {
  install.packages("ggplot2")
  library(ggplot2)
}

filename <- "data.csv"
initial_capital <- 1000000 

options(scipen = 999)

if (!file.exists(filename)) {
  stop(paste("Error: File not found:", filename))
}

data <- read.csv(filename)

# ---------------------------------------------------------
# 2. Calculations (FIXED)
# ---------------------------------------------------------
cap_bot <- initial_capital * (1 + (data$roi_bot / 100))
cap_std <- initial_capital * (1 + (data$roi_std / 100))

# B. Wealth Ratio Vector
ratios_capital <- cap_bot / cap_std

# C. Prepare Data for Plotting
df_plot <- data.frame(
  roi_bot = data$roi_bot,
  roi_std = data$roi_std,
  ratio = ratios_capital
)

# ---------------------------------------------------------
# 3. Statistical Analysis (95% CI)
# ---------------------------------------------------------

# TEST 1: ROI Difference 
test_diff_roi <- t.test(data$roi_bot, data$roi_std, 
                        paired = TRUE, conf.level = 0.95)

# TEST 2: Efficiency Ratio
test_ratio <- t.test(ratios_capital, conf.level = 0.95)

# ---------------------------------------------------------
# 4. Console Output (English)
# ---------------------------------------------------------
cat("=================================================\n")
cat(" PERFORMANCE ANALYSIS (95% CI)\n")
cat(" Base Capital: 1,000,000\n")
cat("=================================================\n\n")

# --- BLOCK 1: PERCENTAGE DIFFERENCE ---
cat("1. ROI DIFFERENCE (Percentage Points)\n")
cat("   Mean Diff:", round(test_diff_roi$estimate, 3), "%\n")
cat("   95% CI   : [", round(test_diff_roi$conf.int[1], 3), "% , ", 
    round(test_diff_roi$conf.int[2], 3), "% ]\n\n")

# --- BLOCK 2: CAPITAL RATIO ---
cat("2. EFFICIENCY RATIO (Wealth Ratio)\n")
cat("   Mean Ratio:", round(test_ratio$estimate, 4), "x\n")
cat("   95% CI    : [", round(test_ratio$conf.int[1], 4), "x , ", 
    round(test_ratio$conf.int[2], 4), "x ]\n\n")

# ---------------------------------------------------------
# 5. Plotting Distribution
# ---------------------------------------------------------
cat("Generating plot...\n")

mean_val <- test_ratio$estimate

p <- ggplot(df_plot, aes(x = ratio)) +
  geom_histogram(aes(y = after_stat(density)), bins = 30, 
                 fill = "#69b3a2", color = "white", alpha = 0.6) +
  geom_density(alpha = 0.2, fill = "#69b3a2", color = "#404080", linewidth = 1) +
  geom_vline(aes(xintercept = 1), color = "red", linetype = "dashed", linewidth = 1) +
  annotate("text", x = 1, y = 0, label = "Neutral (1.0)", 
           vjust = -1, angle = 90, color = "red", hjust = -0.1) +
  geom_vline(aes(xintercept = mean_val), color = "blue", linewidth = 1) +
  annotate("text", x = mean_val, y = 0, label = paste("Mean:", round(mean_val, 3)), 
           vjust = -1, angle = 90, color = "blue", hjust = -0.1) +
  labs(title = "Distribution of Wealth Ratio (Bot vs Standard)",
       subtitle = "Ratio > 1.0 means Bot outperforms Standard",
       x = "Ratio (Bot Capital / Standard Capital)",
       y = "Density") +
  theme_minimal()

print(p)
ggsave("ratio_distribution.png", plot = p, width = 8, height = 6)

cat("Plot saved.\n")
cat("=================================================\n")
