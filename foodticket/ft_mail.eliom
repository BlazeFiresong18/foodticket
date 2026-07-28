(* Outbound email.  Plain-text mail (OTPs) goes through Letters/SMTP
   directly.  QR emails need an inline PNG attachment, which Letters
   0.4 cannot build, so they are delegated to the Python helper in
   services/qr_mailer/ — the OCaml core remains the orchestrator. *)

let smtp_config () =
  Letters.Config.create ~username:Ft_config.smtp_user ~password:Ft_config.smtp_pass
    ~hostname:Ft_config.smtp_host ~with_starttls:false ()
  |> Letters.Config.set_port (Some Ft_config.smtp_port)

let send_plain ~to_email ~subject ~text =
  match
    Letters.create_email ~from:Ft_config.smtp_from ~recipients:[ Letters.To to_email ] ~subject
      ~body:(Letters.Plain text) ()
  with
  | Ok message ->
      Lwt.catch
        (fun () ->
          let%lwt () =
            Letters.send ~config:(smtp_config ()) ~sender:Ft_config.smtp_user
              ~recipients:[ Letters.To to_email ] ~message
          in
          Lwt.return true)
        (fun exn ->
          Ft_log.error "email_send_failed" [ ("to", to_email); ("exn", Printexc.to_string exn) ];
          Lwt.return false)
  | Error e ->
      Ft_log.error "email_build_failed" [ ("to", to_email); ("err", e) ];
      Lwt.return false

let send_otp ~to_email ~otp =
  send_plain ~to_email ~subject:"Your FoodTicket OTP"
    ~text:(Printf.sprintf "Your FoodTicket OTP is: %s\n\nIt expires in 10 minutes." otp)

let send_password_reset ~to_email ~reset_url =
  send_plain ~to_email ~subject:"Reset your FoodTicket password"
    ~text:
      (Printf.sprintf
         "We received a request to reset your FoodTicket password.\n\n\
          Reset it here (valid for 1 hour): %s\n\n\
          If you didn't request this, you can ignore this email — your password won't change."
         reset_url)

(* ---- QR emails via the Python helper --------------------------------- *)

let qr_mailer_path = Ft_config.get_or "FT_QR_MAILER" "services/qr_mailer/qr_mailer.py"

(* recipients: (email, name, qr_payload).  Returns (sent_count, failed
   emails).  The helper reads one JSON object on stdin and prints one
   JSON object on stdout; SMTP credentials never touch the command line. *)
let send_qr_emails recipients =
  let payload =
    `Assoc
      [
        ( "smtp",
          `Assoc
            [
              ("host", `String Ft_config.smtp_host);
              ("port", `Int Ft_config.smtp_port);
              ("user", `String Ft_config.smtp_user);
              ("pass", `String Ft_config.smtp_pass);
              ("from", `String Ft_config.smtp_from);
            ] );
        ("base_url", `String Ft_config.base_url);
        ( "recipients",
          `List
            (List.map
               (fun (email, name, qr_payload) ->
                 `Assoc
                   [ ("email", `String email); ("name", `String name); ("qr", `String qr_payload) ])
               recipients) );
      ]
  in
  let input = Yojson.Safe.to_string payload in
  Lwt.catch
    (fun () ->
      let%lwt output = Lwt_process.pmap ~timeout:600. ("", [| "python3"; qr_mailer_path |]) input in
      match Yojson.Safe.from_string output with
      | `Assoc fields ->
          let results =
            match List.assoc_opt "results" fields with Some (`List l) -> l | _ -> []
          in
          let sent, failed =
            List.fold_left
              (fun (sent, failed) r ->
                match r with
                | `Assoc f ->
                    let email =
                      match List.assoc_opt "email" f with Some (`String e) -> e | _ -> "?"
                    in
                    let ok = match List.assoc_opt "ok" f with Some (`Bool b) -> b | _ -> false in
                    if ok then (sent + 1, failed) else (sent, email :: failed)
                | _ -> (sent, failed))
              (0, []) results
          in
          List.iter (fun e -> Ft_log.error "qr_email_failed" [ ("to", e) ]) failed;
          Lwt.return (sent, List.rev failed)
      | _ ->
          Ft_log.error "qr_mailer_bad_output" [ ("output", Ft_util.truncate 500 output) ];
          Lwt.return (0, List.map (fun (e, _, _) -> e) recipients))
    (fun exn ->
      Ft_log.error "qr_mailer_failed" [ ("exn", Printexc.to_string exn) ];
      Lwt.return (0, List.map (fun (e, _, _) -> e) recipients))
