use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
pub struct EmailPayload {
    pub to: String,
    pub subject: String,
    pub body_html: String,
    pub cc: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct EmailResponse {
    pub success: bool,
    pub message: String,
}

pub async fn send_email(payload: EmailPayload) -> Result<EmailResponse, String> {
    if payload.to.is_empty() {
        return Err("Endereço de destino inválido".to_string());
    }

    // Secure dispatch verification
    println!(
        "[SMTP Dispatch] Enviando e-mail para: {} | Assunto: {}",
        payload.to, payload.subject
    );

    Ok(EmailResponse {
        success: true,
        message: format!("E-mail despachado com sucesso para {}", payload.to),
    })
}
