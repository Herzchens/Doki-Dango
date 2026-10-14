use doki_dango_host::credentials::ProtectedCredentialFile;
use std::{
    env,
    io::{self, Read},
    path::PathBuf,
    process,
};

fn main() {
    if let Err(error) = run() {
        eprintln!("credential harness failed: {error}");
        process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args_os();
    let _program = args.next();
    let command = args
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or("missing command")?;
    let path = args.next().map(PathBuf::from).ok_or("missing path")?;

    if args.next().is_some() {
        return Err("unexpected extra arguments".into());
    }

    let store = ProtectedCredentialFile::new(path);

    match command.as_str() {
        "write" => {
            let secret = read_stdin()?;
            store.save(&secret)?;
            println!("WRITE_OK bytes={}", secret.len());
        }
        "verify" => {
            let expected = read_stdin()?;
            let actual = store.load()?.ok_or("credential file is missing")?;
            if actual.as_bytes() != expected {
                return Err("credential payload mismatch".into());
            }
            println!("VERIFY_OK bytes={}", actual.as_bytes().len());
        }
        "delete" => {
            let deleted = store.delete()?;
            println!("DELETE_OK deleted={deleted}");
        }
        _ => return Err("unsupported command".into()),
    }

    Ok(())
}

fn read_stdin() -> io::Result<Vec<u8>> {
    let mut input = Vec::new();
    io::stdin().read_to_end(&mut input)?;
    Ok(input)
}
