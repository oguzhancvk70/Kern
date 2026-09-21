// kabuk entegrasyonu: zsh (ZDOTDIR vekili) ve bash (--rcfile) için OSC 7/133 kancaları
use std::collections::HashMap;
use std::path::PathBuf;

const ZSH_HOOKS: &str = r#"
__kern_precmd() {
  local e=$?
  printf '\e]133;D;%s\a' "$e"
  printf '\e]7;file://%s%s\a' "${HOST:-localhost}" "${PWD// /%20}"
  printf '\e]133;A\a'
}
__kern_preexec() { printf '\e]133;C\a' }
typeset -ga precmd_functions preexec_functions
precmd_functions+=(__kern_precmd)
preexec_functions+=(__kern_preexec)
"#;

const BASH_RC: &str = r#"
[ -f /etc/profile ] && . /etc/profile
if [ -f ~/.bash_profile ]; then . ~/.bash_profile; elif [ -f ~/.bashrc ]; then . ~/.bashrc; fi
__kern_ran=0
__kern_prompt() {
  local e=$?
  [ "$__kern_ran" = 1 ] && printf '\e]133;D;%s\a' "$e"
  __kern_ran=0
  printf '\e]7;file://%s%s\a' "${HOSTNAME:-localhost}" "${PWD// /%20}"
  printf '\e]133;A\a'
}
__kern_debug() { [ "$__kern_ran" = 0 ] && [ "$BASH_COMMAND" != "__kern_prompt" ] && { __kern_ran=1; printf '\e]133;C\a'; }; }
trap '__kern_debug' DEBUG
PROMPT_COMMAND="__kern_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
"#;

fn dir() -> PathBuf {
    let uid = unsafe { libc::getuid() };
    std::env::temp_dir().join(format!("kern-shell-{uid}"))
}

// (özel kabuk komutu, ortam değişkenleri); başarısızsa entegrasyonsuz varsayılan kabuk
pub fn setup() -> (Option<(String, Vec<String>)>, HashMap<String, String>) {
    let mut env = HashMap::new();
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
    let name = shell.rsplit('/').next().unwrap_or("");
    let base = dir();
    match name {
        "zsh" => {
            let z = base.join("zsh");
            if std::fs::create_dir_all(&z).is_err() {
                return (None, env);
            }
            // kullanıcının dosyalarını sırayla yükle, ZDOTDIR'i bizde tut, sonunda geri ver
            let src =
                |f: &str| format!("[ -f \"$KERN_USER_ZDOTDIR/{f}\" ] && ZDOTDIR=\"$KERN_USER_ZDOTDIR\" . \"$KERN_USER_ZDOTDIR/{f}\"\n");
            let files = [
                (".zshenv", src(".zshenv")),
                (".zprofile", src(".zprofile")),
                (".zshrc", format!("{}{ZSH_HOOKS}", src(".zshrc"))),
                (".zlogin", format!("{}ZDOTDIR=\"$KERN_USER_ZDOTDIR\"\n", src(".zlogin"))),
            ];
            for (f, body) in files {
                if std::fs::write(z.join(f), body).is_err() {
                    return (None, env);
                }
            }
            let user = std::env::var("ZDOTDIR").or_else(|_| std::env::var("HOME")).unwrap_or_default();
            env.insert("KERN_USER_ZDOTDIR".into(), user);
            env.insert("ZDOTDIR".into(), z.to_string_lossy().into_owned());
            (Some((shell, vec!["-l".into()])), env)
        }
        "bash" => {
            let rc = base.join("bashrc");
            if std::fs::create_dir_all(&base).is_err() || std::fs::write(&rc, BASH_RC).is_err() {
                return (None, env);
            }
            (Some((shell, vec!["--rcfile".into(), rc.to_string_lossy().into_owned(), "-i".into()])), env)
        }
        _ => (None, env),
    }
}
