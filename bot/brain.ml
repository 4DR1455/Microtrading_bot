(* --- Configuration & Constants --- *)

(* Minimum % change required to define a discrete 'range' unit *)
let min_margin = 0.1

(* Maximum deviation considered for aggressive trading scaling *)
let max_margin = 0.5

(* Size of the sliding window for Moving Average calculation *)
let max_history_size = 1000 

(* Level of the curve that defines buying progression *)
let level = 2.25

(* --- Data Structures --- *)

(* Inventory Map:
   Key   = Range Index (int representing price level)
   Value = Quantity of shares held at that range
*)
module PriceMap = Map.Make(Int)

(* --- Parsing Utilities --- *)

let parse_input input_str =
  let parts = String.split_on_char ';' input_str in
  match parts with
  | [budget; price; shares] -> 
      (try Some (float_of_string budget, float_of_string price, int_of_string shares)
       with _ -> None)
  | _ -> None

(* --- History Management (Moving Average Logic for FLOAT RATIOS) --- *)

(* Updates the FIFO queue used for the Ratio Average.
   - Adds the new float value to the head.
   - Maintains a maximum size.
   - Updates the running sum in floats.
*)
let update_history_float queue current_sum new_val max_len =
  (* Add new value to the front *)
  let extended_queue = new_val :: queue in
  
  (* If queue exceeds max size, remove the oldest element (tail) *)
  if List.length extended_queue > max_len then
    let rec remove_last_and_get_val = function
      | [] -> ([], 0.0) (* Should not happen *)
      | [x] -> ([], x) (* Base case: last element found *)
      | h :: t -> 
          let (new_t, removed) = remove_last_and_get_val t in
          (h :: new_t, removed)
    in
    let (trimmed_queue, removed_val) = remove_last_and_get_val extended_queue in
    (* Update sum by subtracting the removed value *)
    (trimmed_queue, current_sum +. new_val -. removed_val)
  else
    (* Queue not full yet, simply add to sum *)
    (extended_queue, current_sum +. new_val)


(* Function to get amount of shares operating *)
let shares_amount max_r current_r max_shares =
  (* Avoid division by zero if ranges match perfectly *)
  if max_r = 0.0 then 0
  else
    let x = current_r /. max_r in
    (* Ensure x is within 0.0 - 1.0 range for the formula *)
    let x_clamped = max 0.0 (min 1.0 x) in
    let y = 1.0 -. (1.0 -. x_clamped ** level) ** (1.0 /. level) in
    int_of_float (float_of_int max_shares *. y)


(* --- Main Strategy Loop --- *)

(* Recursive loop maintaining the state of the trading bot.
   State variables:
   - prev_price:    Price from the previous tick.
   - momentum:      Accumulated percentage change.
   - inventory:     Map of currently held shares.
   - ratio_history: List of recent PRICE RATIOS (current/prev).
   - ratio_sum:     Running sum of ratios (optimization).
   - output_channel: Pipe to communicate with C++.
*)
let rec trading_loop prev_price momentum inventory ratio_history ratio_sum output_channel =
  try
    (* Read from Standard Input (Blocking wait for C++ data) *)
    let input_line_raw = input_line stdin in

    match parse_input input_line_raw with
    | Some (budget_raw, current_price, total_shares_real) ->

        let budget = budget_raw *. 0.999 in

      (* 1. Calculate Change (Ratio) & Momentum (CURRENT REALITY) *)

        let current_ratio =  
          if prev_price = 0.0 then 1.0
          else current_price /. prev_price 
        in

        (* Update Momentum (Accumulated Change) *)
        let new_momentum = momentum *. current_ratio in
        let new_pct_acc = (new_momentum -. 1.0) *. 100.0 in
        
        (* Calculate Actual Range *)
        let range_f = new_pct_acc /. min_margin in
        let current_range = int_of_float range_f in
        
      (* 2. Calculate Prediction based on PAST History (PURE PREDICTION) *)
        (* CRITICAL CHANGE: We use the existing 'ratio_history' BEFORE adding the current_ratio *)
        
        let history_count = List.length ratio_history in
        
        (* Average Ratio: The expected movement per tick based on history *)
        let avg_ratio = 
          if history_count > 0 then ratio_sum /. (float_of_int history_count)
          else 1.0 
        in

        (* PREDICTION: What would be the momentum if we followed the average ratio? *)
        (* We apply avg_ratio to the PREVIOUS momentum to see where we "should" be now *)
        let predicted_momentum = momentum *. avg_ratio in
        let predicted_pct_acc = (predicted_momentum -. 1.0) *. 100.0 in
        let predicted_range_f = predicted_pct_acc /. min_margin in
        let predicted_range = int_of_float predicted_range_f in

      (* 3. Update History for NEXT tick *)
        (* Now we add the current_ratio so it's available for the next iteration's prediction *)
        let (new_ratio_history, new_ratio_sum) = update_history_float ratio_history ratio_sum current_ratio max_history_size in

        (* --- DECISION LOGIC --- *)
        (* Compare amount of shares we would buy and amount of shares we would sell *)
        let (action_str, new_inventory, final_momentum) = 
          
          (* BUY QTY *)
          let qty_to_buy = 
            let max_qty = int_of_float (budget /. current_price) in
            let max_ranges_diff = max_margin /. min_margin in
            
            (* How far below prediction are we? *)
            let diff_from_prediction = 
              if current_range < predicted_range then float_of_int (predicted_range - current_range) 
              else 0.0
            in
            
            (* Scale quantity *)
            let qty_to_buy_raw = shares_amount max_ranges_diff diff_from_prediction max_qty in
            
            (* Budget safety check *)
            if float_of_int qty_to_buy_raw *. current_price > budget then
              int_of_float (budget /. current_price)
            else if qty_to_buy_raw < 0 then 0
            else qty_to_buy_raw
          in
          
          (* SELL QTY *)
          let max_qty_to_sell = 
            let max_ranges_diff = max_margin /. min_margin in
            
             (* How far above prediction are we? *)
            let diff_from_prediction = 
              if current_range > predicted_range then float_of_int (current_range - predicted_range)
              else 0.0
            in
            
            let qty_to_sell_raw = shares_amount max_ranges_diff diff_from_prediction total_shares_real in
            
            if qty_to_sell_raw > total_shares_real then total_shares_real
            else if qty_to_sell_raw < 0 then 0
            else qty_to_sell_raw
          in

          (* Logic: Sell shares bought at lower ranges *)
          let qty_to_sell_raw_calc = 
            PriceMap.fold (fun buy_range qty_held shares_sold ->
              if shares_sold < max_qty_to_sell && buy_range < current_range - 2 then shares_sold + qty_held
              else shares_sold
              ) inventory 0
            in
            let qty_to_sell =
              if qty_to_sell_raw_calc > total_shares_real then total_shares_real
              else if qty_to_sell_raw_calc < 0 then 0
              else qty_to_sell_raw_calc
            in
            
          (* CASE A: BUY *)
          if qty_to_buy > qty_to_sell then
            let updated_map = 
              let current_qty = try PriceMap.find current_range inventory with Not_found -> 0 in
              PriceMap.add current_range (current_qty + qty_to_buy) inventory
            in
            ("BUY " ^ string_of_int (qty_to_buy - qty_to_sell), updated_map, new_momentum)

          (* CASE B: SELL *)
          else if qty_to_sell > qty_to_buy then
            let q_s = qty_to_sell - qty_to_buy in
            let (dum_var, updated_map) = 
              if q_s == total_shares_real then
                (0, PriceMap.empty)
              else
                (
                  PriceMap.fold (fun buy_range qty_held (shares_sold, shares_map) ->
                    let remaining_needed = q_s - shares_sold in

                    if remaining_needed <= 0 then
                      (shares_sold, PriceMap.add buy_range qty_held shares_map)
                    else if buy_range >= (current_range - 2) then
                      (shares_sold, PriceMap.add buy_range qty_held shares_map)
                    else
                      if qty_held > remaining_needed then
                        let kept_qty = qty_held - remaining_needed in
                        (shares_sold + remaining_needed, PriceMap.add buy_range kept_qty shares_map)
                      else
                        (shares_sold + qty_held, shares_map)
                  ) inventory (0, PriceMap.empty)
                )
            in
            ("SELL " ^ string_of_int q_s, updated_map, new_momentum)
          
          (* CASE C: HOLD *)
          else 
            ("HOLD", inventory, new_momentum)
        in

        (* --- COMMUNICATION --- *)
        output_string output_channel (action_str ^ " 0\n");
        flush output_channel;

        (* Recursive Call: Pass updated state (with new history) to next tick *)
        trading_loop current_price final_momentum new_inventory new_ratio_history new_ratio_sum output_channel

    | None -> 
        trading_loop prev_price momentum inventory ratio_history ratio_sum output_channel

  with End_of_file ->
    print_endline "[BRAIN] Offline. End of stream."

(* --- Entry Point --- *)
let () =
  print_endline "--- Brain (Strategic Module) Online ---";
  let pipe = open_out "trading_pipe" in
  
  try
    (* Initialize loop with zeroed state *)
    trading_loop 0.0 1.0 PriceMap.empty [] 0.0 pipe
  with _ ->
    close_out pipe
