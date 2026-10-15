use doki_dango_host::{
    credentials::ProtectedCredentialFile,
    fcm::{FcmDataMessage, FcmSender},
    protocol::ProtocolEnvelope,
};
use std::{env, fs, process};

fn main() {
    if let Err(error) = run() {
        eprintln!("production FCM sender harness failed: {error}");
        process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args_os();
    let _program = args.next();
    let credential_path = args.next().ok_or("missing credential path")?;
    let fid_path = args.next().ok_or("missing FID path")?;
    let test_id = args
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or("missing test ID")?;
    let sent_at = args
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or("missing sent_at")?;
    let expires_at = args
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or("missing expires_at")?;

    if args.next().is_some() {
        return Err("unexpected extra arguments".into());
    }
    if !test_id.starts_with("DOKI-B-PROD-") {
        return Err("test ID must start with DOKI-B-PROD-".into());
    }

    let fid_raw = fs::read_to_string(fid_path)?;
    let fid = fid_raw.trim();
    if fid.is_empty() {
        return Err("FID file is empty".into());
    }

    let store = ProtectedCredentialFile::new(credential_path);
    let sender = FcmSender::from_protected_credential_file(&store)?;

    let envelope = ProtocolEnvelope {
        message_id: test_id.clone(),
        pair_id: "runtime-test-pair".to_string(),
        kind: "synthetic.production-fcm".to_string(),
        source_id: "windows-host-runtime".to_string(),
        source_revision: 1,
        sent_at,
        expires_at,
        payload: serde_json::json!({
            "synthetic": true,
            "test_id": test_id,
        }),
        sender_seq: None,
    };

    let mut data = envelope.to_fcm_data()?;
    data.insert("doki_test_id".to_string(), envelope.message_id.clone());

    let mut message = FcmDataMessage::new(fid, data);
    message.android_package_name = Some("dev.dokidango.bharness".to_string());
    message.ttl_seconds = 60;

    let receipt = sender.send(&message)?;

    println!(
        "SEND_OK test_id={} project_id={} attempts={} response_name_length={}",
        envelope.message_id,
        sender.project_id(),
        receipt.attempts,
        receipt.name.len()
    );

    Ok(())
}
