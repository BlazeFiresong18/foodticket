[%%shared
open Eliom_lib
open Eliom_content
open Html.D
]

module Foodticket_app =
  Eliom_registration.App (
  struct
    let application_name = "foodticket"
    let global_data_path = None
  end)

(* ==== JSON responses and handler plumbing ============================= *)

let send_json ?code content =
  Eliom_registration.String.send ?code
    ~content_type:"application/json" (content, "application/json")

let json_escape = Ft_util.json_escape

(* Every API handler runs inside this wrapper: exceptions are logged and
   turned into a clean JSON error; prod never leaks internals. *)
let api_handler name f get post =
  Lwt.catch
    (fun () -> f get post)
    (fun exn ->
       Ft_log.error "api_exception"
         [ ("endpoint", name); ("exn", Printexc.to_string exn) ];
       let body =
         if Ft_config.is_prod then {|{"status":"error"}|}
         else
           Printf.sprintf {|{"status":"error","detail":"%s"}|}
             (json_escape (Printexc.to_string exn))
       in
       send_json ~code:500 body)

(* Role gate for APIs: 403 with no detail when the session lacks the role. *)
let with_role roles f get post =
  let%lwt u = Ft_auth.require roles in
  match u with
  | None -> send_json ~code:403 {|{"status":"forbidden"}|}
  | Some u -> f u get post

let client_ip () =
  try Eliom_request_info.get_remote_ip () with _ -> "unknown"

(* ==== DB helpers shared by handlers =================================== *)

let log_scan db ~scanner_id ~raw ~matched ~result =
  let raw = Ft_util.truncate 500 raw in
  ignore
    (Ft_db.exec db
       (Printf.sprintf
          "INSERT INTO scan_logs (scanner_user_id, raw_payload, \
           matched_user_id, result) VALUES (%s,'%s',%s,'%s')"
          (match scanner_id with Some i -> string_of_int i | None -> "NULL")
          (Ft_db.escape raw)
          (match matched with Some i -> string_of_int i | None -> "NULL")
          (Ft_db.escape result)))

let audit db ~admin_id ~action ~target ~details =
  ignore
    (Ft_db.exec db
       (Printf.sprintf
          "INSERT INTO admin_audit_log (admin_user_id, action, target, \
           details) VALUES (%d,'%s','%s','%s')"
          admin_id (Ft_db.escape action) (Ft_db.escape target)
          (Ft_db.escape (Ft_util.truncate 2000 details))))

let redeemed_today db ~user_id ~email =
  let res =
    Ft_db.exec db
      (Printf.sprintf
         "SELECT id FROM redemptions WHERE (user_id=%d OR email='%s') AND \
          DATE(redeemed_at)=CURDATE() LIMIT 1"
         user_id (Ft_db.escape email))
  in
  Mysql.size res > Int64.zero

let create_otp db ~email =
  let otp = Ft_util.generate_otp () in
  ignore
    (Ft_db.exec db
       (Printf.sprintf "DELETE FROM otps WHERE email='%s'" (Ft_db.escape email)));
  ignore
    (Ft_db.exec db
       (Printf.sprintf
          "INSERT INTO otps (email, code, expires_at) VALUES ('%s','%s', \
           NOW() + INTERVAL 10 MINUTE)"
          (Ft_db.escape email) otp));
  otp

(* QR payload is "FT1:" ^ 43-char base64url token. *)
let parse_qr_payload payload =
  let payload = String.trim payload in
  let token =
    if String.length payload > 4 && String.sub payload 0 4 = "FT1:" then
      String.sub payload 4 (String.length payload - 4)
    else payload
  in
  let valid_char c =
    (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
    || (c >= '0' && c <= '9') || c = '-' || c = '_'
  in
  if String.length token = 43 then begin
    let ok = ref true in
    String.iter (fun c -> if not (valid_char c) then ok := false) token;
    if !ok then Some token else None
  end
  else None

let find_user_by_token db token =
  let res =
    Ft_db.exec db
      (Printf.sprintf
         "SELECT id, email, name, is_active FROM users WHERE qr_token='%s' \
          LIMIT 1"
         (Ft_db.escape token))
  in
  match Mysql.fetch res with
  | Some [| Some id; Some email; Some name; Some active |] ->
    Some (int_of_string id, email, name, active = "1")
  | _ -> None

(* ==== Services ======================================================== *)

let main_service =
  Eliom_service.create ~path:(Eliom_service.Path [])
    ~meth:(Eliom_service.Get Eliom_parameter.unit) ()

let login_service =
  Eliom_service.create ~path:(Eliom_service.Path ["login"])
    ~meth:(Eliom_service.Get Eliom_parameter.unit) ()

let register_service =
  Eliom_service.create ~path:(Eliom_service.Path ["register"])
    ~meth:(Eliom_service.Get Eliom_parameter.unit) ()

let dashboard_service =
  Eliom_service.create ~path:(Eliom_service.Path ["dashboard"])
    ~meth:(Eliom_service.Get Eliom_parameter.unit) ()

let scanner_service =
  Eliom_service.create ~path:(Eliom_service.Path ["scanner"])
    ~meth:(Eliom_service.Get Eliom_parameter.unit) ()

let admin_service =
  Eliom_service.create ~path:(Eliom_service.Path ["admin"])
    ~meth:(Eliom_service.Get Eliom_parameter.unit) ()

let post_api path params =
  Eliom_service.create ~path:(Eliom_service.Path path)
    ~meth:(Eliom_service.Post (Eliom_parameter.unit, params)) ()

let api_login =
  post_api ["api"; "login"] Eliom_parameter.(string "email" ** string "password")

let api_register_user =
  post_api ["api"; "register-user"]
    Eliom_parameter.(string "email" ** string "name" ** string "password")

let api_logout = post_api ["api"; "logout"] Eliom_parameter.unit

let api_scan_verify =
  post_api ["api"; "scan"; "verify"] Eliom_parameter.(string "payload")

let api_scan_confirm =
  post_api ["api"; "scan"; "confirm"]
    Eliom_parameter.(string "payload" ** string "code")

let api_admin_users = post_api ["api"; "admin"; "users"] Eliom_parameter.unit

let api_admin_user_update =
  post_api ["api"; "admin"; "user-update"]
    Eliom_parameter.(
      int "id" ** string "name" ** string "email" ** string "role"
      ** string "is_active" ** string "password")

let api_admin_user_delete =
  post_api ["api"; "admin"; "user-delete"] Eliom_parameter.(int "id")

let api_admin_user_create =
  post_api ["api"; "admin"; "user-create"]
    Eliom_parameter.(
      string "email" ** string "name" ** string "password" ** string "role")

let api_admin_send_qr =
  post_api ["api"; "admin"; "send-qr"] Eliom_parameter.(string "ids")

let api_admin_scan_logs =
  post_api ["api"; "admin"; "scan-logs"] Eliom_parameter.unit

let api_admin_audit_logs =
  post_api ["api"; "admin"; "audit-logs"] Eliom_parameter.unit

(* ==== Auth APIs ======================================================= *)

let () =
  Eliom_registration.Any.register ~service:api_login
    (api_handler "login" (fun () (email, password) ->
       let ip = client_ip () in
       if
         not
           (Ft_util.rate_allow ~key:("login-ip:" ^ ip) ~limit:30
              ~window_s:600.
            && Ft_util.rate_allow ~key:("login-email:" ^ email) ~limit:5
                 ~window_s:600.)
       then begin
         Ft_log.warn "rate_limited" [ ("endpoint", "login"); ("ip", ip) ];
         send_json ~code:429 {|{"status":"rate_limited"}|}
       end
       else if not (Ft_util.is_valid_email email) then
         send_json {|{"status":"invalid_credentials"}|}
       else begin
         let row =
           Ft_db.with_db (fun db ->
               let res =
                 Ft_db.exec db
                   (Printf.sprintf
                      "SELECT id, name, password, role, is_active FROM users \
                       WHERE email='%s' LIMIT 1"
                      (Ft_db.escape email))
               in
               Mysql.fetch res)
         in
         match row with
         | Some [| Some id; Some name; Some pw_hash; Some role; Some active |]
           when active = "1" && Ft_auth.verify_password ~password ~hash:pw_hash
           ->
           let%lwt () =
             Ft_auth.set_logged_in
               { Ft_auth.id = int_of_string id; email; name; role }
           in
           Ft_log.info "login_ok" [ ("email", email); ("ip", ip) ];
           send_json
             (Printf.sprintf
                {|{"status":"success","name":"%s","role":"%s"}|}
                (json_escape name) role)
         | _ ->
           (* Identical response for unknown email / wrong password /
              deactivated account: no user enumeration. *)
           Ft_log.warn "login_fail" [ ("email", email); ("ip", ip) ];
           send_json {|{"status":"invalid_credentials"}|}
       end))

let () =
  Eliom_registration.Any.register ~service:api_register_user
    (api_handler "register-user" (fun () (email, (name, password)) ->
       let ip = client_ip () in
       if not (Ft_util.rate_allow ~key:("register:" ^ ip) ~limit:5
                 ~window_s:3600.)
       then send_json ~code:429 {|{"status":"rate_limited"}|}
       else if not (Ft_util.is_valid_email email) then
         send_json {|{"status":"invalid_email"}|}
       else if not (Ft_util.is_valid_name name) then
         send_json {|{"status":"invalid_name"}|}
       else if not (Ft_util.is_valid_password password) then
         send_json {|{"status":"weak_password"}|}
       else begin
         let hash = Ft_auth.hash_password password in
         let status =
           Ft_db.with_db (fun db ->
               let res =
                 Ft_db.exec db
                   (Printf.sprintf
                      "SELECT id FROM users WHERE email='%s' LIMIT 1"
                      (Ft_db.escape email))
               in
               if Mysql.size res > Int64.zero then `Exists
               else begin
                 let token = Ft_util.new_token () in
                 ignore
                   (Ft_db.exec db
                      (Printf.sprintf
                         "INSERT INTO users (email, name, password, role, \
                          qr_token, qr_issued_at) VALUES \
                          ('%s','%s','%s','customer','%s',NOW())"
                         (Ft_db.escape email) (Ft_db.escape name)
                         (Ft_db.escape hash) token));
                 `Created
               end)
         in
         match status with
         | `Exists -> send_json {|{"status":"already_registered"}|}
         | `Created ->
           Ft_log.info "user_registered" [ ("email", email); ("ip", ip) ];
           send_json {|{"status":"success"}|}
       end))

let () =
  Eliom_registration.Any.register ~service:api_logout
    (api_handler "logout" (fun () () ->
       let%lwt () = Ft_auth.logout () in
       send_json {|{"status":"success"}|}))

(* ==== Scanner APIs ==================================================== *)

let () =
  Eliom_registration.Any.register ~service:api_scan_verify
    (api_handler "scan-verify"
       (with_role [ "scanner"; "admin" ] (fun staff () payload ->
          let staff_id = staff.Ft_auth.id in
          if
            not
              (Ft_util.rate_allow
                 ~key:("scan:" ^ string_of_int staff_id)
                 ~limit:30 ~window_s:60.)
          then send_json ~code:429 {|{"status":"rate_limited"}|}
          else
            match parse_qr_payload payload with
            | None ->
              Ft_db.with_db (fun db ->
                  log_scan db ~scanner_id:(Some staff_id) ~raw:payload
                    ~matched:None ~result:"invalid_token");
              Ft_log.warn "scan_invalid"
                [ ("scanner", staff.Ft_auth.email);
                  ("payload", Ft_util.truncate 100 payload) ];
              send_json {|{"status":"invalid"}|}
            | Some token ->
              let outcome =
                Ft_db.with_db (fun db ->
                    match find_user_by_token db token with
                    | None ->
                      log_scan db ~scanner_id:(Some staff_id) ~raw:payload
                        ~matched:None ~result:"invalid_token";
                      `Invalid
                    | Some (uid, email, name, active) ->
                      if not active then begin
                        log_scan db ~scanner_id:(Some staff_id) ~raw:payload
                          ~matched:(Some uid) ~result:"inactive_user";
                        `Inactive name
                      end
                      else if redeemed_today db ~user_id:uid ~email then begin
                        log_scan db ~scanner_id:(Some staff_id) ~raw:payload
                          ~matched:(Some uid) ~result:"cooldown";
                        `Cooldown name
                      end
                      else begin
                        let otp = create_otp db ~email in
                        log_scan db ~scanner_id:(Some staff_id) ~raw:payload
                          ~matched:(Some uid) ~result:"otp_sent";
                        `OtpNeeded (email, name, otp)
                      end)
              in
              (match outcome with
               | `Invalid ->
                 Ft_log.warn "scan_invalid"
                   [ ("scanner", staff.Ft_auth.email) ];
                 send_json {|{"status":"invalid"}|}
               | `Inactive name ->
                 send_json
                   (Printf.sprintf {|{"status":"inactive","name":"%s"}|}
                      (json_escape name))
               | `Cooldown name ->
                 send_json
                   (Printf.sprintf
                      {|{"status":"already_redeemed","name":"%s"}|}
                      (json_escape name))
               | `OtpNeeded (email, name, otp) ->
                 let%lwt sent = Ft_mail.send_otp ~to_email:email ~otp in
                 if sent then
                   send_json
                     (Printf.sprintf
                        {|{"status":"otp_sent","name":"%s","masked_email":"%s"}|}
                        (json_escape name)
                        (json_escape (Ft_util.mask_email email)))
                 else send_json {|{"status":"email_failed"}|}))))

let () =
  Eliom_registration.Any.register ~service:api_scan_confirm
    (api_handler "scan-confirm"
       (with_role [ "scanner"; "admin" ] (fun staff () (payload, code) ->
          let staff_id = staff.Ft_auth.id in
          let code = String.trim code in
          if not (String.length code = 6 && Ft_util.is_digits code) then
            send_json {|{"status":"invalid_otp"}|}
          else
            match parse_qr_payload payload with
            | None -> send_json {|{"status":"invalid"}|}
            | Some token ->
              let outcome =
                Ft_db.with_db (fun db ->
                    match find_user_by_token db token with
                    | None -> `Invalid
                    | Some (uid, email, name, _active) ->
                      if redeemed_today db ~user_id:uid ~email then begin
                        log_scan db ~scanner_id:(Some staff_id) ~raw:payload
                          ~matched:(Some uid) ~result:"cooldown";
                        `Cooldown name
                      end
                      else begin
                        let res =
                          Ft_db.exec db
                            (Printf.sprintf
                               "SELECT id FROM otps WHERE email='%s' AND \
                                code='%s' AND expires_at > NOW() AND used=0 \
                                LIMIT 1"
                               (Ft_db.escape email) (Ft_db.escape code))
                        in
                        if Mysql.size res = Int64.zero then begin
                          log_scan db ~scanner_id:(Some staff_id)
                            ~raw:payload ~matched:(Some uid)
                            ~result:"otp_failed";
                          `BadOtp
                        end
                        else begin
                          ignore
                            (Ft_db.exec db
                               (Printf.sprintf
                                  "UPDATE otps SET used=1 WHERE email='%s' \
                                   AND code='%s'"
                                  (Ft_db.escape email) (Ft_db.escape code)));
                          ignore
                            (Ft_db.exec db
                               (Printf.sprintf
                                  "INSERT INTO redemptions (email, user_id, \
                                   scanner_user_id) VALUES ('%s',%d,%d)"
                                  (Ft_db.escape email) uid staff_id));
                          log_scan db ~scanner_id:(Some staff_id)
                            ~raw:payload ~matched:(Some uid)
                            ~result:"redeemed";
                          `Done name
                        end
                      end)
              in
              (match outcome with
               | `Invalid -> send_json {|{"status":"invalid"}|}
               | `Cooldown name ->
                 send_json
                   (Printf.sprintf
                      {|{"status":"already_redeemed","name":"%s"}|}
                      (json_escape name))
               | `BadOtp -> send_json {|{"status":"invalid_otp"}|}
               | `Done name ->
                 Ft_log.info "redemption"
                   [ ("customer", name); ("scanner", staff.Ft_auth.email) ];
                 send_json
                   (Printf.sprintf {|{"status":"success","name":"%s"}|}
                      (json_escape name))))))

(* ==== Admin APIs ====================================================== *)

let () =
  Eliom_registration.Any.register ~service:api_admin_users
    (api_handler "admin-users"
       (with_role [ "admin" ] (fun _admin () () ->
          let rows =
            Ft_db.with_db (fun db ->
                Ft_db.fetch_all
                  (Ft_db.exec db
                     ("SELECT id, email, name, role, is_active, "
                      ^ "DATE_FORMAT(created_at,'%Y-%m-%d %H:%i'), "
                      ^ "IFNULL(DATE_FORMAT(qr_issued_at,'%Y-%m-%d %H:%i'),'') "
                      ^ "FROM users ORDER BY id")))
          in
          let users =
            List.filter_map
              (fun row ->
                 match row with
                 | [| id; email; name; role; active; created; qr_at |] ->
                   Some
                     (`Assoc
                       [
                         ("id", `Int (int_of_string (Ft_db.s id)));
                         ("email", `String (Ft_db.s email));
                         ("name", `String (Ft_db.s name));
                         ("role", `String (Ft_db.s role));
                         ("is_active", `Bool (Ft_db.s active = "1"));
                         ("created_at", `String (Ft_db.s created));
                         ("qr_issued_at", `String (Ft_db.s qr_at));
                       ])
                 | _ -> None)
              rows
          in
          send_json
            (Yojson.Safe.to_string
               (`Assoc
                 [ ("status", `String "success"); ("users", `List users) ])))))

let () =
  Eliom_registration.Any.register ~service:api_admin_user_update
    (api_handler "admin-user-update"
       (with_role [ "admin" ]
          (fun admin () (id, (name, (email, (role, (is_active, password))))) ->
             if not (Ft_util.is_valid_email email) then
               send_json {|{"status":"invalid_email"}|}
             else if not (Ft_util.is_valid_name name) then
               send_json {|{"status":"invalid_name"}|}
             else if not (Ft_util.is_valid_role role) then
               send_json {|{"status":"invalid_role"}|}
             else if password <> "" && not (Ft_util.is_valid_password password)
             then send_json {|{"status":"weak_password"}|}
             else if id = admin.Ft_auth.id && role <> "admin" then
               send_json {|{"status":"cannot_change_own_role"}|}
             else begin
               let active = if is_active = "true" then 1 else 0 in
               let pw_clause =
                 if password = "" then ""
                 else
                   Printf.sprintf ", password='%s'"
                     (Ft_db.escape (Ft_auth.hash_password password))
               in
               let updated =
                 Ft_db.with_db (fun db ->
                     ignore
                       (Ft_db.exec db
                          (Printf.sprintf
                             "UPDATE users SET name='%s', email='%s', \
                              role='%s', is_active=%d%s WHERE id=%d"
                             (Ft_db.escape name) (Ft_db.escape email)
                             (Ft_db.escape role) active pw_clause id));
                     let n = Mysql.affected db in
                     audit db ~admin_id:admin.Ft_auth.id ~action:"user.update"
                       ~target:(string_of_int id)
                       ~details:
                         (Printf.sprintf
                            "name=%s email=%s role=%s active=%d pw_changed=%b"
                            name email role active (password <> ""));
                     n)
               in
               ignore updated;
               Ft_log.info "admin_user_update"
                 [ ("admin", admin.Ft_auth.email); ("target", string_of_int id) ];
               send_json {|{"status":"success"}|}
             end)))

let () =
  Eliom_registration.Any.register ~service:api_admin_user_delete
    (api_handler "admin-user-delete"
       (with_role [ "admin" ] (fun admin () id ->
          if id = admin.Ft_auth.id then
            send_json {|{"status":"cannot_delete_self"}|}
          else begin
            let deleted =
              Ft_db.with_db (fun db ->
                  let res =
                    Ft_db.exec db
                      (Printf.sprintf
                         "SELECT email FROM users WHERE id=%d LIMIT 1" id)
                  in
                  match Mysql.fetch res with
                  | Some [| Some email |] ->
                    ignore
                      (Ft_db.exec db
                         (Printf.sprintf "DELETE FROM users WHERE id=%d" id));
                    ignore
                      (Ft_db.exec db
                         (Printf.sprintf "DELETE FROM otps WHERE email='%s'"
                            (Ft_db.escape email)));
                    audit db ~admin_id:admin.Ft_auth.id ~action:"user.delete"
                      ~target:(string_of_int id) ~details:("email=" ^ email);
                    true
                  | _ -> false)
            in
            if deleted then begin
              Ft_log.warn "admin_user_delete"
                [ ("admin", admin.Ft_auth.email); ("target", string_of_int id) ];
              send_json {|{"status":"success"}|}
            end
            else send_json {|{"status":"not_found"}|}
          end)))

let () =
  Eliom_registration.Any.register ~service:api_admin_user_create
    (api_handler "admin-user-create"
       (with_role [ "admin" ] (fun admin () (email, (name, (password, role))) ->
          if not (Ft_util.is_valid_email email) then
            send_json {|{"status":"invalid_email"}|}
          else if not (Ft_util.is_valid_name name) then
            send_json {|{"status":"invalid_name"}|}
          else if not (Ft_util.is_valid_password password) then
            send_json {|{"status":"weak_password"}|}
          else if not (Ft_util.is_valid_role role) then
            send_json {|{"status":"invalid_role"}|}
          else begin
            let hash = Ft_auth.hash_password password in
            let status =
              Ft_db.with_db (fun db ->
                  let res =
                    Ft_db.exec db
                      (Printf.sprintf
                         "SELECT id FROM users WHERE email='%s' LIMIT 1"
                         (Ft_db.escape email))
                  in
                  if Mysql.size res > Int64.zero then `Exists
                  else begin
                    let token = Ft_util.new_token () in
                    ignore
                      (Ft_db.exec db
                         (Printf.sprintf
                            "INSERT INTO users (email, name, password, role, \
                             qr_token, qr_issued_at) VALUES \
                             ('%s','%s','%s','%s','%s',NOW())"
                            (Ft_db.escape email) (Ft_db.escape name)
                            (Ft_db.escape hash) (Ft_db.escape role) token));
                    audit db ~admin_id:admin.Ft_auth.id ~action:"user.create"
                      ~target:email ~details:("role=" ^ role);
                    `Created
                  end)
            in
            match status with
            | `Exists -> send_json {|{"status":"already_registered"}|}
            | `Created -> send_json {|{"status":"success"}|}
          end)))

let () =
  Eliom_registration.Any.register ~service:api_admin_send_qr
    (api_handler "admin-send-qr"
       (with_role [ "admin" ] (fun admin () ids ->
          let where =
            if String.trim ids = "all" then
              Some "role='customer' AND is_active=1"
            else begin
              let id_list =
                String.split_on_char ',' ids
                |> List.filter_map (fun s -> int_of_string_opt (String.trim s))
              in
              if id_list = [] then None
              else
                Some
                  (Printf.sprintf "id IN (%s)"
                     (String.concat ","
                        (List.map string_of_int id_list)))
            end
          in
          match where with
          | None -> send_json {|{"status":"invalid_input"}|}
          | Some where ->
            let targets =
              Ft_db.with_db (fun db ->
                  let rows =
                    Ft_db.fetch_all
                      (Ft_db.exec db
                         ("SELECT id, email, name FROM users WHERE " ^ where))
                  in
                  let targets =
                    List.filter_map
                      (fun row ->
                         match row with
                         | [| Some id; Some email; Some name |] ->
                           (* Rotate: a fresh token invalidates any
                              previously issued QR for this customer. *)
                           let t = Ft_util.new_token () in
                           ignore
                             (Ft_db.exec db
                                (Printf.sprintf
                                   "UPDATE users SET qr_token='%s', \
                                    qr_issued_at=NOW() WHERE id=%s"
                                   t id));
                           Some (email, name, "FT1:" ^ t)
                         | _ -> None)
                      rows
                  in
                  audit db ~admin_id:admin.Ft_auth.id ~action:"qr.send"
                    ~target:(Ft_util.truncate 255 ids)
                    ~details:
                      (Printf.sprintf "recipients=%d" (List.length targets));
                  targets)
            in
            if targets = [] then send_json {|{"status":"no_recipients"}|}
            else begin
              Ft_log.info "qr_send_started"
                [ ("admin", admin.Ft_auth.email);
                  ("count", string_of_int (List.length targets)) ];
              let%lwt sent, failed = Ft_mail.send_qr_emails targets in
              send_json
                (Yojson.Safe.to_string
                   (`Assoc
                     [
                       ("status", `String "success");
                       ("sent", `Int sent);
                       ( "failed",
                         `List (List.map (fun e -> `String e) failed) );
                     ]))
            end)))

let () =
  Eliom_registration.Any.register ~service:api_admin_scan_logs
    (api_handler "admin-scan-logs"
       (with_role [ "admin" ] (fun _admin () () ->
          let rows =
            Ft_db.with_db (fun db ->
                Ft_db.fetch_all
                  (Ft_db.exec db
                     ("SELECT l.id, IFNULL(su.name,'?'), l.raw_payload, "
                      ^ "IFNULL(cu.name,''), IFNULL(cu.email,''), l.result, "
                      ^ "DATE_FORMAT(l.created_at,'%Y-%m-%d %H:%i:%s') "
                      ^ "FROM scan_logs l "
                      ^ "LEFT JOIN users su ON su.id = l.scanner_user_id "
                      ^ "LEFT JOIN users cu ON cu.id = l.matched_user_id "
                      ^ "ORDER BY l.id DESC LIMIT 200")))
          in
          let logs =
            List.filter_map
              (fun row ->
                 match row with
                 | [| id; scanner; raw; cname; cemail; result; at |] ->
                   Some
                     (`Assoc
                       [
                         ("id", `Int (int_of_string (Ft_db.s id)));
                         ("scanner", `String (Ft_db.s scanner));
                         ("payload", `String (Ft_util.truncate 60 (Ft_db.s raw)));
                         ("customer_name", `String (Ft_db.s cname));
                         ("customer_email", `String (Ft_db.s cemail));
                         ("result", `String (Ft_db.s result));
                         ("at", `String (Ft_db.s at));
                       ])
                 | _ -> None)
              rows
          in
          send_json
            (Yojson.Safe.to_string
               (`Assoc
                 [ ("status", `String "success"); ("logs", `List logs) ])))))

let () =
  Eliom_registration.Any.register ~service:api_admin_audit_logs
    (api_handler "admin-audit-logs"
       (with_role [ "admin" ] (fun _admin () () ->
          let rows =
            Ft_db.with_db (fun db ->
                Ft_db.fetch_all
                  (Ft_db.exec db
                     ("SELECT a.id, IFNULL(u.name,'?'), a.action, a.target, "
                      ^ "a.details, DATE_FORMAT(a.created_at,'%Y-%m-%d %H:%i:%s') "
                      ^ "FROM admin_audit_log a "
                      ^ "LEFT JOIN users u ON u.id = a.admin_user_id "
                      ^ "ORDER BY a.id DESC LIMIT 200")))
          in
          let logs =
            List.filter_map
              (fun row ->
                 match row with
                 | [| id; admin_name; action; target; details; at |] ->
                   Some
                     (`Assoc
                       [
                         ("id", `Int (int_of_string (Ft_db.s id)));
                         ("admin", `String (Ft_db.s admin_name));
                         ("action", `String (Ft_db.s action));
                         ("target", `String (Ft_db.s target));
                         ("details", `String (Ft_db.s details));
                         ("at", `String (Ft_db.s at));
                       ])
                 | _ -> None)
              rows
          in
          send_json
            (Yojson.Safe.to_string
               (`Assoc
                 [ ("status", `String "success"); ("logs", `List logs) ])))))

(* ==== Pages =========================================================== *)

let page ~title:t elts =
  Eliom_tools.F.html ~title:t ~css:[ [ "css"; "foodticket.css" ] ]
    (Html.F.body elts)

let page_script path =
  Html.F.(script ~a:[ a_src (Xml.uri_of_string path) ] (txt ""))

let hero elts = Html.F.(div ~a:[ a_class [ "hero" ] ] elts)

let access_denied ~needed =
  page ~title:"Access denied"
    Html.F.[
      hero
        [
          h1 ~a:[ a_class [ "title" ] ] [ txt "Access denied" ];
          p ~a:[ a_class [ "subtitle" ] ]
            [ txt ("This page requires " ^ needed ^ " access.") ];
          p
            [
              a ~service:login_service ~a:[ a_class [ "login-btn" ] ]
                [ txt "Login" ] ();
            ];
        ];
    ]

let () =
  Foodticket_app.register ~service:main_service (fun () () ->
      let%lwt user = Ft_auth.current_user () in
      Lwt.return
        (page ~title:"FoodTicket"
           Html.F.[
             hero
               [
                 h1 ~a:[ a_class [ "title" ] ] [ txt "FoodTicket" ];
                 h2 ~a:[ a_class [ "subtitle" ] ]
                   [ txt "Digital Food Coupon Management System" ];
                 (match user with
                  | None ->
                    p
                      [
                        a ~service:login_service
                          ~a:[ a_class [ "login-btn" ] ] [ txt "Login" ] ();
                      ]
                  | Some user ->
                    div
                      [
                        p [ txt ("Signed in as " ^ user.Ft_auth.name) ];
                        p
                          [
                            (match user.Ft_auth.role with
                             | "admin" ->
                               a ~service:admin_service
                                 ~a:[ a_class [ "login-btn" ] ]
                                 [ txt "Admin dashboard" ] ()
                             | "scanner" ->
                               a ~service:scanner_service
                                 ~a:[ a_class [ "login-btn" ] ]
                                 [ txt "Scanner" ] ()
                             | _ ->
                               a ~service:dashboard_service
                                 ~a:[ a_class [ "login-btn" ] ]
                                 [ txt "My dashboard" ] ());
                          ];
                      ]);
               ];
           ]))

let () =
  Foodticket_app.register ~service:login_service (fun () () ->
      Lwt.return
        (page ~title:"Login"
           Html.F.[
             hero
               [
                 h1 ~a:[ a_class [ "title" ] ] [ txt "Login" ];
                 p ~a:[ a_class [ "subtitle" ] ] [ txt "Sign in to continue" ];
                 div ~a:[ a_id "login-container" ] [];
                 p ~a:[ a_id "auth-status" ] [ txt "" ];
                 page_script "/js/auth.js";
                 p
                   [
                     a ~service:register_service ~a:[ a_class [ "login-btn" ] ]
                       [ txt "New here? Register" ] ();
                   ];
               ];
           ]))

let () =
  Foodticket_app.register ~service:register_service (fun () () ->
      Lwt.return
        (page ~title:"Register"
           Html.F.[
             hero
               [
                 h1 ~a:[ a_class [ "title" ] ] [ txt "Register" ];
                 p ~a:[ a_class [ "subtitle" ] ] [ txt "Create your account" ];
                 div ~a:[ a_id "register-container" ] [];
                 p ~a:[ a_id "auth-status" ] [ txt "" ];
                 page_script "/js/auth.js";
                 p
                   [
                     a ~service:login_service ~a:[ a_class [ "login-btn" ] ]
                       [ txt "Already have an account? Login" ] ();
                   ];
               ];
           ]))

(* Customer dashboard: their QR code + redemption status/history. *)
let () =
  Foodticket_app.register ~service:dashboard_service (fun () () ->
      let%lwt user = Ft_auth.current_user () in
      match user with
      | None -> Lwt.return (access_denied ~needed:"a logged-in account")
      | Some user ->
        let token, redeemed, history =
          Ft_db.with_db (fun db ->
              let token =
                let res =
                  Ft_db.exec db
                    (Printf.sprintf
                       "SELECT qr_token FROM users WHERE id=%d LIMIT 1"
                       user.Ft_auth.id)
                in
                match Mysql.fetch res with
                | Some [| Some t |] when t <> "" -> t
                | _ ->
                  (* First visit before any admin send: assign a token so
                     the dashboard always has a QR to show. *)
                  let t = Ft_util.new_token () in
                  ignore
                    (Ft_db.exec db
                       (Printf.sprintf
                          "UPDATE users SET qr_token='%s', \
                           qr_issued_at=NOW() WHERE id=%d"
                          t user.Ft_auth.id));
                  t
              in
              let redeemed =
                redeemed_today db ~user_id:user.Ft_auth.id
                  ~email:user.Ft_auth.email
              in
              let history =
                Ft_db.fetch_all
                  (Ft_db.exec db
                     (Printf.sprintf
                        "SELECT DATE_FORMAT(redeemed_at,'%%Y-%%m-%%d %%H:%%i') \
                         FROM redemptions WHERE (user_id=%d OR email='%s') \
                         ORDER BY redeemed_at DESC LIMIT 30"
                        user.Ft_auth.id
                        (Ft_db.escape user.Ft_auth.email)))
                |> List.filter_map (fun row ->
                    match row with [| d |] -> Some (Ft_db.s d) | _ -> None)
              in
              (token, redeemed, history))
        in
        Lwt.return
          (page ~title:"My FoodTicket"
             Html.F.[
               hero
                 [
                   h1 ~a:[ a_class [ "title" ] ] [ txt "My FoodTicket" ];
                   p ~a:[ a_class [ "subtitle" ] ]
                     [ txt ("Welcome, " ^ user.Ft_auth.name) ];
                   div
                     ~a:
                       [
                         a_id "qr-box";
                         a_user_data "token" ("FT1:" ^ token);
                       ]
                     [];
                   p
                     ~a:
                       [
                         a_id "redeem-status";
                         a_class
                           [ (if redeemed then "status-bad" else "status-ok") ];
                       ]
                     [
                       txt
                         (if redeemed then
                            "Already redeemed today — next meal tomorrow."
                          else "Available: show this QR at the counter.");
                     ];
                   h2 [ txt "Redemption history" ];
                   (if history = [] then p [ txt "No redemptions yet." ]
                    else
                      table
                        ~a:[ a_class [ "data-table" ] ]
                        (tr [ th [ txt "Redeemed at" ] ]
                         :: List.map (fun d -> tr [ td [ txt d ] ]) history));
                   p
                     [
                       button
                         ~a:[ a_id "logout-btn"; a_class [ "login-btn" ] ]
                         [ txt "Logout" ];
                     ];
                   page_script "/js/vendor/qrcode.min.js";
                   page_script "/js/customer.js";
                 ];
             ]))

(* Scanner dashboard: staff scan customer QRs. *)
let () =
  Foodticket_app.register ~service:scanner_service (fun () () ->
      let%lwt staff = Ft_auth.require [ "scanner"; "admin" ] in
      match staff with
      | None -> Lwt.return (access_denied ~needed:"scanner staff")
      | Some staff ->
        Lwt.return
          (page ~title:"Scanner"
             Html.F.[
               hero
                 [
                   h1 ~a:[ a_class [ "title" ] ] [ txt "Scanner" ];
                   p ~a:[ a_class [ "subtitle" ] ]
                     [ txt ("Operator: " ^ staff.Ft_auth.name) ];
                   div ~a:[ a_id "qr-reader" ] [];
                   div ~a:[ a_id "scan-panel" ] [];
                   p ~a:[ a_id "qr-status" ] [ txt "Loading scanner..." ];
                   p
                     [
                       button
                         ~a:[ a_id "logout-btn"; a_class [ "login-btn" ] ]
                         [ txt "Logout" ];
                     ];
                   page_script "/js/scanner.js";
                 ];
             ]))

(* Admin dashboard shell; data arrives via the admin APIs. *)
let () =
  Foodticket_app.register ~service:admin_service (fun () () ->
      let%lwt admin = Ft_auth.require [ "admin" ] in
      match admin with
      | None -> Lwt.return (access_denied ~needed:"admin")
      | Some admin ->
        Lwt.return
          (page ~title:"Admin"
             Html.F.[
               div
                 ~a:[ a_class [ "admin-wrap" ] ]
                 [
                   h1 ~a:[ a_class [ "title" ] ] [ txt "Admin dashboard" ];
                   p ~a:[ a_class [ "subtitle" ] ]
                     [ txt ("Signed in as " ^ admin.Ft_auth.name) ];
                   div
                     ~a:[ a_id "admin-tabs" ]
                     [
                       button ~a:[ a_id "tab-users"; a_class [ "tab-btn" ] ]
                         [ txt "Customers" ];
                       button
                         ~a:[ a_id "tab-scans"; a_class [ "tab-btn" ] ]
                         [ txt "Scan log" ];
                       button
                         ~a:[ a_id "tab-audit"; a_class [ "tab-btn" ] ]
                         [ txt "Audit log" ];
                       button
                         ~a:[ a_id "logout-btn"; a_class [ "tab-btn" ] ]
                         [ txt "Logout" ];
                     ];
                   p ~a:[ a_id "admin-status" ] [ txt "" ];
                   div ~a:[ a_id "admin-content" ] [];
                   page_script "/js/admin.js";
                 ];
             ]))
