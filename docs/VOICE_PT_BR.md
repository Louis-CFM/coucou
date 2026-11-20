# Brazilian Portuguese voice control

On the macOS GitHub build, open **Settings → Voice**, turn on voice control and choose **Português** for **You speak** and **Coucou answers in**. The two choices are independent, so you can also speak Portuguese and hear English or French.

Say **“OK Coucou”** or **“Ei Coucou”**, then try:

- **“Toca música”** or **“pausa”** to control playback.
- **“Adiciona o GitHub”** or **“tira o Stripe”** to manage pills.
- **“Qual é o meu saldo no Stripe?”** to ask about a connected service.
- **“Qual é a previsão do tempo amanhã?”** after enabling weather and setting a city in Voice settings.
- **“Manda um e-mail pra Ana”** to prepare an email. Coucou asks for the missing details and opens a draft; sending still requires a click.
- **“Obrigado”** or **“tchau”** to end the conversation.

Recognition uses Apple's on-device speech recognizer. Portuguese availability depends on the recognition languages installed on your Mac. If it is unavailable, Coucou tries the other available on-device languages. If no Portuguese system voice is installed for spoken replies, add one in macOS Accessibility settings.

These settings control the voice assistant. Flow dictation's optional Parakeet model is selected separately. Choosing Portuguese does not enable Claude, web search or ElevenLabs; those keep their existing opt-in settings.
