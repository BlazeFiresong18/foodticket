(* Application configuration.
   Values come from environment variables first, then from a .env file
   (path in FT_ENV_FILE, default "./.env").  Required values fail fast
   at server startup so a misconfigured deployment never half-runs. *)

let env_file_values =
  lazy
    (let path = Option.value (Sys.getenv_opt "FT_ENV_FILE") ~default:".env" in
     let tbl = Hashtbl.create 16 in
     (try
        let ic = open_in path in
        (try
           while true do
             let line = String.trim (input_line ic) in
             if line <> "" && line.[0] <> '#' then
               match String.index_opt line '=' with
               | Some i ->
                   let k = String.trim (String.sub line 0 i) in
                   let v = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
                   let v =
                     let n = String.length v in
                     if
                       n >= 2
                       && ((v.[0] = '"' && v.[n - 1] = '"') || (v.[0] = '\'' && v.[n - 1] = '\''))
                     then String.sub v 1 (n - 2)
                     else v
                   in
                   Hashtbl.replace tbl k v
               | None -> ()
           done
         with End_of_file -> ());
        close_in ic
      with Sys_error _ -> ());
     tbl)

let get name =
  match Sys.getenv_opt name with
  | Some v when v <> "" -> Some v
  | _ -> Hashtbl.find_opt (Lazy.force env_file_values) name

let get_or name default = match get name with Some v -> v | None -> default

let require name =
  match get name with
  | Some v -> v
  | None ->
      failwith
        (Printf.sprintf
           "FoodTicket: missing required configuration %s (set the environment variable or add it \
            to .env)"
           name)

let env = get_or "FT_ENV" "dev"
let is_prod = env = "prod"
let db_host = get_or "FT_DB_HOST" "127.0.0.1"
let db_port = int_of_string (get_or "FT_DB_PORT" "3306")
let db_name = get_or "FT_DB_NAME" "foodticket"
let db_user = get_or "FT_DB_USER" "foodticket"
let db_pass = require "FT_DB_PASS"
let smtp_host = get_or "FT_SMTP_HOST" "smtp.gmail.com"
let smtp_port = int_of_string (get_or "FT_SMTP_PORT" "465")
let smtp_user = require "FT_SMTP_USER"
let smtp_pass = require "FT_SMTP_PASS"
let smtp_from = get_or "FT_SMTP_FROM" ("FoodTicket <" ^ smtp_user ^ ">")

(* Public base URL used in emails (dashboard links). *)
let base_url = get_or "FT_BASE_URL" "http://localhost:8080"
