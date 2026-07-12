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

let db_connect () =
  Mysql.connect {
    Mysql.dbhost   = Some "127.0.0.1";
    Mysql.dbname   = Some "foodticket";
    Mysql.dbport   = Some 3306;
    Mysql.dbuser   = Some "foodticket";
Mysql.dbpwd    = Some "REDACTED";
    Mysql.dbsocket = None;
  }

let db_query db sql = Mysql.exec db sql
let escape _db s = Mysql.escape s

let gmail_user = "aaryankaneria18@gmail.com"
let gmail_pass = "REDACTED-ROTATE-ME"
let gmail_from = "FoodTicket <aaryankaneria18@gmail.com>"

let send_otp_email ~to_email ~otp =
  let body = Letters.Plain (Printf.sprintf
    "Your FoodTicket OTP is: %s\n\nIt expires in 10 minutes." otp) in
  let config = Letters.Config.create
    ~username:gmail_user
    ~password:gmail_pass
    ~hostname:"smtp.gmail.com"
    ~with_starttls:false
    ()
    |> Letters.Config.set_port (Some 465)
  in
  match Letters.create_email
    ~from:gmail_from
    ~recipients:[Letters.To to_email]
    ~subject:"Your FoodTicket OTP"
    ~body
    () with
  | Ok message ->
    Letters.send ~config ~sender:gmail_user
      ~recipients:[Letters.To to_email] ~message
  | Error e ->
    Printf.printf "Email build error: %s\n%!" e;
    Lwt.return ()

let generate_otp () =
  Random.self_init ();
  Printf.sprintf "%06d" (Random.int 1000000)

let main_service =
  Eliom_service.create
    ~path:(Eliom_service.Path [])
    ~meth:(Eliom_service.Get Eliom_parameter.unit)
    ()

let login_service =
  Eliom_service.create
    ~path:(Eliom_service.Path ["login"])
    ~meth:(Eliom_service.Get Eliom_parameter.unit)
    ()

let register_service =
  Eliom_service.create
    ~path:(Eliom_service.Path ["register"])
    ~meth:(Eliom_service.Get Eliom_parameter.unit)
    ()

let dashboard_service =
  Eliom_service.create
    ~path:(Eliom_service.Path ["dashboard"])
    ~meth:(Eliom_service.Get Eliom_parameter.unit)
    ()

let scan_service =
  Eliom_service.create
    ~path:(Eliom_service.Path ["scan"])
    ~meth:(Eliom_service.Get Eliom_parameter.unit)
    ()

let api_check_email =
  Eliom_service.create
    ~path:(Eliom_service.Path ["api"; "check-email"])
    ~meth:(Eliom_service.Post (
      Eliom_parameter.unit,
      Eliom_parameter.string "email"))
    ()

let api_register =
  Eliom_service.create
    ~path:(Eliom_service.Path ["api"; "register"])
    ~meth:(Eliom_service.Post (
      Eliom_parameter.unit,
      Eliom_parameter.(string "email" ** string "name")))
    ()

let api_verify_otp =
  Eliom_service.create
    ~path:(Eliom_service.Path ["api"; "verify-otp"])
    ~meth:(Eliom_service.Post (
      Eliom_parameter.unit,
      Eliom_parameter.(string "email" ** string "code")))
    ()

let api_login =
  Eliom_service.create
    ~path:(Eliom_service.Path ["api"; "login"])
    ~meth:(Eliom_service.Post (
      Eliom_parameter.unit,
      Eliom_parameter.(string "email" ** string "password")))
    ()

let api_register_user =
  Eliom_service.create
    ~path:(Eliom_service.Path ["api"; "register-user"])
    ~meth:(Eliom_service.Post (
      Eliom_parameter.unit,
      Eliom_parameter.(string "email" ** string "name" ** string "password")))
    ()

let send_json_response content =
  Eliom_registration.String.send
    ~content_type:"application/json"
    (content, "application/json")

let json_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c ->
    match c with
    | '"' -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | _ -> Buffer.add_char buf c) s;
  Buffer.contents buf

let () =
  Eliom_registration.Any.register
    ~service:api_check_email
    (fun () email ->
       let db = db_connect () in
       let e = escape db email in
       let res = db_query db
         (Printf.sprintf "SELECT id FROM users WHERE email='%s' LIMIT 1" e)
       in
       let user_exists = Mysql.size res > Int64.zero in
       if not user_exists then begin
         Mysql.disconnect db;
         send_json_response "{\"status\":\"unregistered\"}"
       end else begin
         let res2 = db_query db
           (Printf.sprintf
             "SELECT id FROM redemptions WHERE email='%s' AND redeemed_at > NOW() - INTERVAL 1 DAY LIMIT 1" e)
         in
         let already = Mysql.size res2 > Int64.zero in
         if already then begin
           Mysql.disconnect db;
           send_json_response "{\"status\":\"already_redeemed\"}"
         end else begin
           let _ = db_query db
             (Printf.sprintf "DELETE FROM otps WHERE email='%s'" e)
           in
           let otp = generate_otp () in
           let _ = db_query db
             (Printf.sprintf
               "INSERT INTO otps (email, code, expires_at) VALUES ('%s','%s', NOW() + INTERVAL 10 MINUTE)" e otp)
           in
           Mysql.disconnect db;
           let%lwt _ = send_otp_email ~to_email:email ~otp in
           send_json_response "{\"status\":\"otp_sent\"}"
         end
       end)

let () =
  Eliom_registration.Any.register
    ~service:api_register
    (fun () (email, name) ->
       let db = db_connect () in
       let e = escape db email in
       let n = escape db name in
       let _ = db_query db
         (Printf.sprintf "INSERT IGNORE INTO users (email, name) VALUES ('%s','%s')" e n)
       in
       let _ = db_query db
         (Printf.sprintf "DELETE FROM otps WHERE email='%s'" e)
       in
       let otp = generate_otp () in
       let _ = db_query db
         (Printf.sprintf
           "INSERT INTO otps (email, code, expires_at) VALUES ('%s','%s', NOW() + INTERVAL 10 MINUTE)" e otp)
       in
       Mysql.disconnect db;
       let%lwt _ = send_otp_email ~to_email:email ~otp in
       send_json_response "{\"status\":\"otp_sent\"}")

let () =
  Eliom_registration.Any.register
    ~service:api_verify_otp
    (fun () (email, code) ->
       let db = db_connect () in
       let e = escape db email in
       let c = escape db code in
       let res = db_query db
         (Printf.sprintf
           "SELECT id FROM otps WHERE email='%s' AND code='%s' AND expires_at > NOW() AND used=0 LIMIT 1" e c)
       in
       let valid = Mysql.size res > Int64.zero in
       if not valid then begin
         Mysql.disconnect db;
         send_json_response "{\"status\":\"invalid_otp\"}"
       end else begin
         let _ = db_query db
           (Printf.sprintf "UPDATE otps SET used=1 WHERE email='%s' AND code='%s'" e c)
         in
         let _ = db_query db
           (Printf.sprintf "INSERT INTO redemptions (email) VALUES ('%s')" e)
         in
         Mysql.disconnect db;
         send_json_response "{\"status\":\"success\"}"
       end)

let () =
  Eliom_registration.Any.register
    ~service:api_login
    (fun () (email, password) ->
       let db = db_connect () in
       let e = escape db email in
       let res = db_query db
         (Printf.sprintf "SELECT name, password FROM users WHERE email='%s' LIMIT 1" e)
       in
       let user_exists = Mysql.size res > Int64.zero in
       if not user_exists then begin
         Mysql.disconnect db;
         send_json_response "{\"status\":\"not_found\"}"
       end else begin
         let name, stored_password =
           match Mysql.fetch res with
           | Some [| Some n; Some p |] -> n, p
           | Some [| Some n; None |] -> n, ""
           | _ -> "", ""
         in
         Mysql.disconnect db;
         if password <> stored_password then
           send_json_response "{\"status\":\"wrong_password\"}"
         else
           send_json_response
             (Printf.sprintf "{\"status\":\"success\",\"name\":\"%s\"}" (json_escape name))
       end)

let () =
  Eliom_registration.Any.register
    ~service:api_register_user
    (fun () (email, (name, password)) ->
       let db = db_connect () in
       let e = escape db email in
       let n = escape db name in
       let p = escape db password in
       let res = db_query db
         (Printf.sprintf "SELECT id FROM users WHERE email='%s' LIMIT 1" e)
       in
       let user_exists = Mysql.size res > Int64.zero in
       if user_exists then begin
         Mysql.disconnect db;
         send_json_response "{\"status\":\"already_registered\"}"
       end else begin
         let _ = db_query db
           (Printf.sprintf
             "INSERT INTO users (email, name, password) VALUES ('%s','%s','%s')" e n p)
         in
         Mysql.disconnect db;
         send_json_response "{\"status\":\"success\"}"
       end)

let () =
  Foodticket_app.register
    ~service:login_service
    (fun () () ->
       Lwt.return
         (Eliom_tools.F.html
            ~title:"Login"
            ~css:[["css";"foodticket.css"]]
            Html.F.(body [
              div ~a:[a_class ["hero"]] [
                h1 ~a:[a_class ["title"]] [txt "Login"];
                p ~a:[a_class ["subtitle"]] [txt "Sign in to continue"];
                div ~a:[a_id "login-container"] [];
                p ~a:[a_id "auth-status"] [txt ""];
                script ~a:[a_src (Xml.uri_of_string "/js/auth.js")] (txt "");
                p [a ~service:register_service ~a:[a_class ["login-btn"]] [txt "New here? Register"] ()];
              ]
            ])))

let () =
  Foodticket_app.register
    ~service:register_service
    (fun () () ->
       Lwt.return
         (Eliom_tools.F.html
            ~title:"Register"
            ~css:[["css";"foodticket.css"]]
            Html.F.(body [
              div ~a:[a_class ["hero"]] [
                h1 ~a:[a_class ["title"]] [txt "Register"];
                p ~a:[a_class ["subtitle"]] [txt "Create your account"];
                div ~a:[a_id "register-container"] [];
                p ~a:[a_id "auth-status"] [txt ""];
                script ~a:[a_src (Xml.uri_of_string "/js/auth.js")] (txt "");
                p [a ~service:login_service ~a:[a_class ["login-btn"]] [txt "Already have an account? Login"] ()];
              ]
            ])))

let () =
  Foodticket_app.register
    ~service:dashboard_service
    (fun () () ->
       Lwt.return
         (Eliom_tools.F.html
            ~title:"Dashboard"
            ~css:[["css";"foodticket.css"]]
            Html.F.(body [
              div ~a:[a_class ["hero"]] [
                h1 ~a:[a_class ["title"]] [txt "Student Dashboard"];
                p ~a:[a_class ["subtitle"]] [txt "Scan cafeteria QR codes"];
                p [a ~service:scan_service ~a:[a_class ["login-btn"]] [txt "Scan QR"] ()];
              ]
            ])))

let () =
  Foodticket_app.register
    ~service:scan_service
    (fun () () ->
       Lwt.return
         (Eliom_tools.F.html
            ~title:"QR Scanner"
            ~css:[["css";"foodticket.css"]]
            Html.F.(body [
              div ~a:[a_class ["hero"]] [
                h1 ~a:[a_class ["title"]] [txt "QR Scanner"];
                p ~a:[a_class ["subtitle"]] [txt "Point your camera at a QR code"];
                div ~a:[a_id "qr-reader"] [];
                p ~a:[a_id "qr-status"] [txt "Waiting for scanner..."];
                pre ~a:[a_id "qr-result"] [txt ""];
                script ~a:[a_src (Xml.uri_of_string "/js/scan.js")] (txt "");
                p [a ~service:dashboard_service ~a:[a_class ["login-btn"]] [txt "Back"] ()];
              ]
            ])))

let () =
  Foodticket_app.register
    ~service:main_service
    (fun () () ->
       Lwt.return
         (Eliom_tools.F.html
            ~title:"FoodTicket"
            ~css:[["css";"foodticket.css"]]
            Html.F.(body [
              div ~a:[a_class ["hero"]] [
                h1 ~a:[a_class ["title"]] [txt "FoodTicket"];
                h2 ~a:[a_class ["subtitle"]] [txt "Digital Food Coupon Management System"];
                p [a ~service:login_service ~a:[a_class ["login-btn"]] [txt "Login"] ()];
              ]
            ])))
