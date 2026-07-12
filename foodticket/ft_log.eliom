(* Structured application logging: one JSON object per line, appended to
   FT_LOG_FILE (default ./foodticket-app.log).  Security-relevant events
   (logins, scans, admin actions) also live in DB tables; this file is
   for operational debugging. *)

let log_path = Ft_config.get_or "FT_LOG_FILE" "foodticket-app.log"

let level_str = function `Info -> "info" | `Warn -> "warn" | `Error -> "error"

let write level event fields =
  let ts =
    let tm = Unix.gmtime (Unix.gettimeofday ()) in
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
  in
  let parts =
    ("ts", ts) :: ("level", level_str level) :: ("event", event) :: fields
  in
  let json =
    "{"
    ^ String.concat ","
        (List.map
           (fun (k, v) ->
              Printf.sprintf "\"%s\":\"%s\"" (Ft_util.json_escape k)
                (Ft_util.json_escape v))
           parts)
    ^ "}"
  in
  try
    let oc = open_out_gen [ Open_append; Open_creat ] 0o640 log_path in
    output_string oc (json ^ "\n");
    close_out oc
  with _ -> prerr_endline ("[log-write-failed] " ^ json)

let info event fields = write `Info event fields
let warn event fields = write `Warn event fields
let error event fields = write `Error event fields
