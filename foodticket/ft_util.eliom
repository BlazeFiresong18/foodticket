(* Server-side utilities: JSON escaping, input validation, secure
   randomness (tokens, OTPs) and an in-memory sliding-window rate
   limiter. *)

let json_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
       match c with
       | '"' -> Buffer.add_string buf "\\\""
       | '\\' -> Buffer.add_string buf "\\\\"
       | '\n' -> Buffer.add_string buf "\\n"
       | '\r' -> Buffer.add_string buf "\\r"
       | '\t' -> Buffer.add_string buf "\\t"
       | c when Char.code c < 32 ->
         Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
       | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

(* ---- validation ------------------------------------------------------ *)

let email_re = Str.regexp {|^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+$|}

let is_valid_email s =
  String.length s > 0 && String.length s <= 254 && Str.string_match email_re s 0

let is_valid_name s =
  let n = String.length s in
  n >= 1 && n <= 100
  &&
  let ok = ref true in
  String.iter (fun c -> if Char.code c < 32 then ok := false) s;
  !ok

let is_valid_password s =
  let n = String.length s in
  n >= 8 && n <= 128

let is_valid_role = function
  | "customer" | "scanner" | "admin" -> true
  | _ -> false

let is_digits s =
  String.length s > 0
  &&
  let ok = ref true in
  String.iter (fun c -> if c < '0' || c > '9' then ok := false) s;
  !ok

(* ---- secure randomness ---------------------------------------------- *)

let urandom n =
  let ic = open_in_bin "/dev/urandom" in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic n)

let b64url = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

let base64url_encode s =
  let n = String.length s in
  let buf = Buffer.create ((n * 4 / 3) + 4) in
  let i = ref 0 in
  while !i + 2 < n do
    let a = Char.code s.[!i]
    and b = Char.code s.[!i + 1]
    and c = Char.code s.[!i + 2] in
    Buffer.add_char buf b64url.[a lsr 2];
    Buffer.add_char buf b64url.[((a land 3) lsl 4) lor (b lsr 4)];
    Buffer.add_char buf b64url.[((b land 15) lsl 2) lor (c lsr 6)];
    Buffer.add_char buf b64url.[c land 63];
    i := !i + 3
  done;
  (match n - !i with
   | 1 ->
     let a = Char.code s.[!i] in
     Buffer.add_char buf b64url.[a lsr 2];
     Buffer.add_char buf b64url.[(a land 3) lsl 4]
   | 2 ->
     let a = Char.code s.[!i] and b = Char.code s.[!i + 1] in
     Buffer.add_char buf b64url.[a lsr 2];
     Buffer.add_char buf b64url.[((a land 3) lsl 4) lor (b lsr 4)];
     Buffer.add_char buf b64url.[(b land 15) lsl 2]
   | _ -> ());
  Buffer.contents buf

(* 32 random bytes as 43 base64url chars; used as the customer QR token and
   password-reset tokens. *)
let new_token () = base64url_encode (urandom 32)

let is_valid_token s =
  String.length s = 43
  &&
  let ok = ref true in
  String.iter
    (fun c ->
       if
         not
           ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
            || (c >= '0' && c <= '9') || c = '-' || c = '_')
       then ok := false)
    s;
  !ok

(* Uniform 6-digit OTP via rejection sampling (no modulo bias). *)
let generate_otp () =
  let rec go () =
    let b = urandom 4 in
    let v =
      (Char.code b.[0] lsl 24)
      lor (Char.code b.[1] lsl 16)
      lor (Char.code b.[2] lsl 8)
      lor Char.code b.[3]
    in
    let v = v land 0x7FFFFFFF in
    if v >= 2_147_000_000 then go ()
    else Printf.sprintf "%06d" (v mod 1_000_000)
  in
  go ()

(* ---- rate limiting ---------------------------------------------------
   Sliding window, in-memory (single-process deployment). *)

let buckets : (string, float list) Hashtbl.t = Hashtbl.create 64

let rate_allow ~key ~limit ~window_s =
  let now = Unix.gettimeofday () in
  if Hashtbl.length buckets > 10_000 then
    (* opportunistic GC of stale buckets *)
    Hashtbl.iter
      (fun k hits ->
         if List.for_all (fun t -> now -. t >= window_s) hits then
           Hashtbl.remove buckets k)
      (Hashtbl.copy buckets);
  let hits =
    match Hashtbl.find_opt buckets key with Some l -> l | None -> []
  in
  let hits = List.filter (fun t -> now -. t < window_s) hits in
  if List.length hits >= limit then begin
    Hashtbl.replace buckets key hits;
    false
  end
  else begin
    Hashtbl.replace buckets key (now :: hits);
    true
  end

(* ---- misc ------------------------------------------------------------ *)

let mask_email e =
  match String.index_opt e '@' with
  | Some i when i > 1 ->
    String.make 1 e.[0] ^ "***" ^ String.sub e (i - 1) (String.length e - i + 1)
  | _ -> "***"

let truncate n s = if String.length s > n then String.sub s 0 n else s
