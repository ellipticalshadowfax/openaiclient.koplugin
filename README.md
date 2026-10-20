# OpenAI Client

A minimal OpenAI-compatible chat client for KOReader. It works with the OpenAI
API as well as self-hosted and third-party servers that implement the
`/v1/chat/completions` and `/v1/models` endpoints, such as Ollama, llama.cpp,
LM Studio, and LLM Gateway.

## Features

- Multiple configurable endpoints with URL, API key, models, system prompt,
  temperature, and timeout
- Select a model from the configured list or enter a custom model name
- Fetch the model list from the server
- Plain-text chat responses shown in a scrollable dialog
- Synchronous HTTP transport that works on devices without the Turbo event loop
- Settings stored in KOReader's `G_reader_settings`

## Requirements

- KOReader with LuaSocket and LuaSec support (standard KOReader builds)
- A network connection
- An API key if your endpoint requires authentication

No API key is bundled with this plugin. Add your own key under
**Tools → OpenAI → Endpoints…**.

## Installation

Copy the `openaiclient.koplugin` directory into the KOReader `plugins`
directory:

```text
koreader/plugins/openaiclient.koplugin/
├── main.lua
├── _meta.lua
└── README.md
```

Restart KOReader after copying the plugin.

## Usage

1. Open the menu and go to **Tools → OpenAI**.
2. Select **Endpoints…** to add or edit an endpoint.
3. Select **Chat…**, choose a model, type a message, and tap **Send**.

### Endpoint fields

| Field | Description |
| --- | --- |
| Name | Display name for the endpoint |
| Base URL | Server root, for example `https://api.openai.com/v1` |
| API key | Bearer token; leave empty for unauthenticated local servers |
| Models | Comma-separated model IDs |
| System prompt | Optional system message prepended to each request |
| Temperature | Sampling temperature from 0 to 2 |
| Timeout | Request timeout in seconds |

The **Fetch model list from server** action queries `GET /models` on the
selected endpoint and replaces the configured model list with the result.

## Notes

- The default endpoint points at LLM Gateway and uses an empty API key. Enter
  your own key before sending a request.
- Requests are synchronous. A slow server will block the UI until the request
  completes or times out.
- API keys are stored in KOReader's settings file in plain text, like other
  plugin settings. Protect access to your device accordingly.

## Development

The plugin was tested against KOReader
`v2026.07.2-267-g63019920c`. For local development, symlink the plugin into a
KOReader checkout and run the emulator:

```sh
ln -s ../../openaiclient.koplugin koreader/plugins/openaiclient.koplugin
cd koreader
./kodev build
./kodev run
```

Run the plugin spec with KOReader's frontend test runner:

```sh
cp spec/openaiclient_spec.lua ../koreader/spec/unit/
cd ../koreader
./kodev test front openaiclient
```

## License

GNU Affero General Public License v3.0. See [LICENSE](LICENSE).
