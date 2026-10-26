import Foundation

/// The `HomeswiftAiKit` platform block in config.json: which provider the Assistant uses, and how.
///
/// ```json
/// { "platform": "HomeswiftAiKit", "provider": "anthropic", "model": "claude-opus-5-5", "apiKey": "sk-ant-…" }
/// { "platform": "HomeswiftAiKit", "provider": "apple" }
/// ```
///
/// The key names are those of `@mp-consulting/homebridge-ai-kit`, so a Homebridge block works unchanged.
/// An API key missing from the block is read from `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` or `GEMINI_API_KEY`.
public struct AIConfiguration: Sendable, Equatable {
    public static let platform = "HomeswiftAiKit"

    public enum ProviderKind: String, Sendable, Codable, CaseIterable {
        case anthropic, openai, gemini
        case openaiCompatible = "openai-compatible"
        /// Apple's on-device model (Foundation Models, macOS 26 or later with Apple Intelligence).
        case apple

        public var defaultModel: String {
            switch self {
            case .anthropic: "claude-opus-5-5"
            case .openai: "gpt-6.1-sol"
            case .gemini: "gemini-3.8-flash"
            case .openaiCompatible: "llama3.1"
            case .apple: "system"
            }
        }

        public var defaultBaseURL: String? {
            switch self {
            case .anthropic: "https://api.anthropic.com"
            case .openai: "https://api.openai.com/v1"
            case .gemini: "https://generativelanguage.googleapis.com/v1beta"
            case .openaiCompatible: "http://127.0.0.1:11434/v1"
            case .apple: nil
            }
        }

        var apiKeyEnvironmentVariable: String? {
            switch self {
            case .anthropic: "ANTHROPIC_API_KEY"
            case .openai: "OPENAI_API_KEY"
            case .gemini: "GEMINI_API_KEY"
            case .openaiCompatible, .apple: nil
            }
        }
    }

    /// OpenAI APIs: the Responses API, or Chat Completions for servers that only speak it.
    public enum OpenAIAPI: String, Sendable, Codable {
        case responses, chat
    }

    public static let defaultMaxOutputTokens = 2048

    /// The block's settings form, in the shape of a plugin's config.schema.json: the web UI's Settings uses it.
    /// It covers the MCP server's part of the block (`mcp.http`) too.
    public static let schemaJSON = #"""
        {
          "pluginAlias": "HomeswiftAiKit",
          "schema": {
            "type": "object",
            "properties": {
              "provider": { "title": "Provider", "type": "string", "default": "anthropic", "required": true, "oneOf": [
                { "title": "Anthropic (Claude)", "enum": ["anthropic"] },
                { "title": "OpenAI", "enum": ["openai"] },
                { "title": "Google Gemini", "enum": ["gemini"] },
                { "title": "OpenAI-compatible (Ollama, LM Studio, a proxy)", "enum": ["openai-compatible"] },
                { "title": "Apple on-device model (macOS 26)", "enum": ["apple"] }
              ], "description": "Who answers. Apple's on-device model is free and private but too small for the chat's tools." },
              "model": { "title": "Model", "type": "string", "placeholder": "claude-opus-5-5", "description": "The model's id, as the provider names it. Empty uses its default: claude-opus-5-5 for Claude, gpt-6.1-sol for OpenAI, gemini-3.8-flash for Gemini, llama3.1 on an OpenAI-compatible server." },
              "apiKey": { "title": "API key", "type": "string", "x-schema-form": { "type": "password" }, "description": "Your key from the provider's console. Empty reads ANTHROPIC_API_KEY, OPENAI_API_KEY or GEMINI_API_KEY from the environment. Never sent anywhere but the provider." },
              "baseUrl": { "title": "Base URL", "type": "string", "placeholder": "http://127.0.0.1:11434/v1", "description": "The server's OpenAI-compatible address, ending in /v1: Ollama's is http://127.0.0.1:11434/v1 (the default), LM Studio's http://127.0.0.1:1234/v1. Also a proxy in front of a provider." },
              "effort": { "title": "Effort", "type": "string", "oneOf": [
                { "title": "Low", "enum": ["low"] },
                { "title": "Medium", "enum": ["medium"] },
                { "title": "High", "enum": ["high"] },
                { "title": "Extra high", "enum": ["xhigh"] },
                { "title": "Max", "enum": ["max"] }
              ], "description": "How long the model thinks before it answers (Claude, OpenAI's reasoning models): higher is more careful, slower and costs more. Empty leaves it to the model." },
              "maxOutputTokens": { "title": "Longest answer (tokens)", "type": "integer", "default": 2048, "minimum": 1, "description": "The most the Assistant writes in one answer, in tokens (a token is about three quarters of a word); a longer answer stops there." },
              "contextTokens": { "title": "Context window (tokens)", "type": "integer", "minimum": 1, "description": "How much the model reads at once, for a local model the bridge cannot ask (8192 is assumed): what it is sent is trimmed to fit." },
              "openaiApi": { "title": "OpenAI API", "type": "string", "oneOf": [
                { "title": "Responses (OpenAI)", "enum": ["responses"] },
                { "title": "Chat Completions (most local servers)", "enum": ["chat"] }
              ], "description": "Which of OpenAI's APIs to call. Empty uses Responses for OpenAI and Chat Completions for a compatible server." },
              "maxRetries": { "title": "Retries", "type": "integer", "default": 2, "minimum": 0, "maximum": 10, "description": "How many times a failed request is tried again (a timeout, a rate limit, a server error, the network). 0 never retries." },
              "promptCaching": { "title": "Prompt caching", "type": "boolean", "default": true, "description": "Claude: keep the system prompt and tools in Anthropic's cache between requests, so they cost less and answer sooner. Turn it off for a proxy that rejects it." },
              "fallbacks": { "title": "Fallback model", "type": "boolean", "description": "Claude: when the model declines a request, let the API run it again on a fallback model. On by default for Opus 5.5, Opus 5, Sonnet 5.5 and Fable." },
              "enabled": { "title": "Enabled", "type": "boolean", "default": true, "description": "Off keeps these settings but turns the Assistant off everywhere, until it is on again." },
              "budget": { "title": "Budget", "type": "object", "description": "Limits per day and per month, local time: once one is used up, requests are refused until it resets. Empty is no limit.", "properties": {
                "dailyTokens": { "title": "Tokens per day", "type": "integer", "minimum": 0, "description": "Tokens the Assistant may use each day, what it reads and what it writes together. Empty is no limit." },
                "monthlyTokens": { "title": "Tokens per month", "type": "integer", "minimum": 0, "description": "The same, for each month." },
                "dailyUsd": { "title": "USD per day", "type": "number", "minimum": 0, "description": "The most it may spend each day, in US dollars. Only Claude models are priced: the others count as free." },
                "monthlyUsd": { "title": "USD per month", "type": "number", "minimum": 0, "description": "The same, for each month." }
              } },
              "mcp": { "title": "MCP server", "type": "object", "description": "Lets Claude Desktop, Claude Code, Cursor and other MCP clients list and set accessories, read the log and change config.json.", "properties": {
                "http": { "title": "Over HTTP", "type": "object", "description": "The server inside the running bridge, over Streamable HTTP at /mcp. homeswift mcp forwards a stdio client to it.", "properties": {
                  "enabled": { "title": "Run the MCP server", "type": "boolean", "default": false, "description": "Lets Claude Desktop and other MCP clients read and control the bridge with a token." },
                  "host": { "title": "Listen on", "type": "string", "placeholder": "127.0.0.1", "description": "The address it listens on: 127.0.0.1 (the default) keeps it to this machine, 0.0.0.0 opens it to your network." },
                  "port": { "title": "Port", "type": "integer", "default": 8582, "minimum": 1, "maximum": 65535, "description": "The port of its /mcp address." },
                  "token": { "title": "Admin token", "type": "string", "x-schema-form": { "type": "password" }, "description": "The main client's token, with admin access; the server needs one. homeswift mcp --generate-token makes one." },
                  "readOnly": { "title": "Read only", "type": "boolean", "description": "Caps every token at read access." },
                  "allowedOrigins": { "title": "Allowed browser origins", "type": "array", "items": { "type": "string" }, "description": "Web pages allowed to call it from a browser, besides localhost and the server's own address, as https://example.com; * allows any." },
                  "auditLog": { "title": "Audit log", "type": "boolean", "default": true, "description": "Every write, with who asked, in homeswift-mcp-audit.jsonl." },
                  "auditLogPath": { "title": "Audit log file", "type": "string", "description": "Where the audit log is written. Empty keeps it next to config.json." },
                  "clients": { "title": "Clients", "type": "array", "description": "More tokens, each with its own access.", "items": { "title": "Client", "type": "object", "properties": {
                    "name": { "title": "Name", "type": "string", "description": "Who uses this token, to tell the tokens apart." },
                    "token": { "title": "Token", "type": "string", "x-schema-form": { "type": "password" }, "description": "The token this client sends." },
                    "scope": { "title": "Scope", "type": "string", "oneOf": [
                      { "title": "Read", "enum": ["read"] },
                      { "title": "Control", "enum": ["control"] },
                      { "title": "Admin", "enum": ["admin"] }
                    ], "description": "Read lists and reads; Control also sets accessories and runs scenes; Admin also changes the configuration and restarts." }
                  } } }
                } }
              } }
            }
          },
          "layout": [
            "provider",
            { "key": "apiKey", "condition": { "functionBody": "return model.provider !== 'apple';" } },
            { "key": "baseUrl", "condition": { "functionBody": "return model.provider === 'openai-compatible';" } },
            { "key": "model", "condition": { "functionBody": "return model.provider !== 'apple';" } },
            { "type": "fieldset", "title": "Answers", "expandable": true, "expanded": false, "items": [
              { "key": "effort", "condition": { "functionBody": "return model.provider === 'anthropic' || model.provider === 'openai';" } },
              "maxOutputTokens",
              { "key": "contextTokens", "condition": { "functionBody": "return model.provider === 'openai-compatible';" } },
              { "key": "openaiApi", "condition": { "functionBody": "return model.provider === 'openai' || model.provider === 'openai-compatible';" } },
              { "key": "promptCaching", "condition": { "functionBody": "return model.provider === 'anthropic';" } },
              { "key": "fallbacks", "condition": { "functionBody": "return model.provider === 'anthropic';" } },
              "maxRetries",
              "enabled"
            ] },
            { "type": "fieldset", "title": "Budget", "expandable": true, "expanded": false, "items": ["budget"] },
            { "type": "fieldset", "title": "MCP server", "expandable": true, "expanded": false, "items": ["mcp"] }
          ],
          "i18n": {
            "fr": {
              "Provider": "Fournisseur",
              "Anthropic (Claude)": "Anthropic (Claude)",
              "OpenAI": "OpenAI",
              "Google Gemini": "Google Gemini",
              "OpenAI-compatible (Ollama, LM Studio, a proxy)": "Compatible OpenAI (Ollama, LM Studio, un proxy)",
              "Apple on-device model (macOS 26)": "Modèle Apple sur l'appareil (macOS 26)",
              "Who answers. Apple's on-device model is free and private but too small for the chat's tools.": "Qui répond. Le modèle d'Apple sur l'appareil est gratuit et privé, mais trop petit pour les outils du chat.",
              "Model": "Modèle",
              "The model's id, as the provider names it. Empty uses its default: claude-opus-5-5 for Claude, gpt-6.1-sol for OpenAI, gemini-3.8-flash for Gemini, llama3.1 on an OpenAI-compatible server.": "L'identifiant du modèle, tel que le fournisseur le nomme. Vide : celui par défaut, claude-opus-5-5 pour Claude, gpt-6.1-sol pour OpenAI, gemini-3.8-flash pour Gemini, llama3.1 sur un serveur compatible OpenAI.",
              "API key": "Clé d'API",
              "Your key from the provider's console. Empty reads ANTHROPIC_API_KEY, OPENAI_API_KEY or GEMINI_API_KEY from the environment. Never sent anywhere but the provider.": "Votre clé, depuis la console du fournisseur. Vide : ANTHROPIC_API_KEY, OPENAI_API_KEY ou GEMINI_API_KEY est lue dans l'environnement. Elle n'est envoyée qu'au fournisseur.",
              "Base URL": "URL de base",
              "The server's OpenAI-compatible address, ending in /v1: Ollama's is http://127.0.0.1:11434/v1 (the default), LM Studio's http://127.0.0.1:1234/v1. Also a proxy in front of a provider.": "L'adresse compatible OpenAI du serveur, terminée par /v1 : celle d'Ollama est http://127.0.0.1:11434/v1 (par défaut), celle de LM Studio http://127.0.0.1:1234/v1. Aussi un proxy devant un fournisseur.",
              "Effort": "Effort",
              "Low": "Faible",
              "Medium": "Moyen",
              "High": "Élevé",
              "Extra high": "Très élevé",
              "Max": "Max",
              "How long the model thinks before it answers (Claude, OpenAI's reasoning models): higher is more careful, slower and costs more. Empty leaves it to the model.": "Le temps que le modèle réfléchit avant de répondre (Claude, les modèles de raisonnement d'OpenAI) : plus haut, il est plus soigneux, plus lent et plus cher. Vide : le modèle décide.",
              "Token": "Jeton",
              "Longest answer (tokens)": "Réponse la plus longue (tokens)",
              "The most the Assistant writes in one answer, in tokens (a token is about three quarters of a word); a longer answer stops there.": "Le maximum que l'Assistant écrit dans une réponse, en tokens (un token vaut environ trois quarts de mot) ; une réponse plus longue s'arrête là.",
              "Context window (tokens)": "Fenêtre de contexte (tokens)",
              "How much the model reads at once, for a local model the bridge cannot ask (8192 is assumed): what it is sent is trimmed to fit.": "Ce que le modèle lit d'un coup, pour un modèle local que le pont ne peut pas interroger (8192 par défaut) : ce qui lui est envoyé est raccourci pour tenir.",
              "OpenAI API": "API OpenAI",
              "Responses (OpenAI)": "Responses (OpenAI)",
              "Chat Completions (most local servers)": "Chat Completions (la plupart des serveurs locaux)",
              "Which of OpenAI's APIs to call. Empty uses Responses for OpenAI and Chat Completions for a compatible server.": "Quelle API d'OpenAI appeler. Vide : Responses pour OpenAI et Chat Completions pour un serveur compatible.",
              "Retries": "Nouvelles tentatives",
              "How many times a failed request is tried again (a timeout, a rate limit, a server error, the network). 0 never retries.": "Combien de fois une requête échouée est retentée (délai dépassé, limite de débit, erreur du serveur, réseau). 0 ne réessaie jamais.",
              "Prompt caching": "Cache des prompts",
              "Claude: keep the system prompt and tools in Anthropic's cache between requests, so they cost less and answer sooner. Turn it off for a proxy that rejects it.": "Claude : garder le prompt système et les outils dans le cache d'Anthropic entre les requêtes, pour qu'elles coûtent moins et répondent plus vite. Désactivez-le pour un proxy qui le refuse.",
              "Fallback model": "Modèle de repli",
              "Claude: when the model declines a request, let the API run it again on a fallback model. On by default for Opus 5.5, Opus 5, Sonnet 5.5 and Fable.": "Claude : quand le modèle refuse une requête, laisser l'API la relancer sur un modèle de repli. Activé par défaut pour Opus 5.5, Opus 5, Sonnet 5.5 et Fable.",
              "Enabled": "Activé",
              "Off keeps these settings but turns the Assistant off everywhere, until it is on again.": "Désactivé, ces réglages sont gardés mais l'Assistant est coupé partout, jusqu'à ce qu'il soit réactivé.",
              "Budget": "Budget",
              "Limits per day and per month, local time: once one is used up, requests are refused until it resets. Empty is no limit.": "Des limites par jour et par mois, à l'heure locale : une fois l'une atteinte, les requêtes sont refusées jusqu'à sa remise à zéro. Vide : pas de limite.",
              "Tokens per day": "Tokens par jour",
              "Tokens the Assistant may use each day, what it reads and what it writes together. Empty is no limit.": "Les tokens que l'Assistant peut utiliser chaque jour, ce qu'il lit et ce qu'il écrit ensemble. Vide : pas de limite.",
              "Tokens per month": "Tokens par mois",
              "The same, for each month.": "La même chose, pour chaque mois.",
              "USD per day": "USD par jour",
              "The most it may spend each day, in US dollars. Only Claude models are priced: the others count as free.": "Le maximum qu'il peut dépenser chaque jour, en dollars américains. Seuls les modèles Claude ont un prix : les autres comptent comme gratuits.",
              "USD per month": "USD par mois",
              "MCP server": "Serveur MCP",
              "Lets Claude Desktop, Claude Code, Cursor and other MCP clients list and set accessories, read the log and change config.json.": "Permet à Claude Desktop, Claude Code, Cursor et aux autres clients MCP de lister et régler les accessoires, de lire le journal et de modifier config.json.",
              "Over HTTP": "Par HTTP",
              "The server inside the running bridge, over Streamable HTTP at /mcp. homeswift mcp forwards a stdio client to it.": "Le serveur intégré au pont en marche, en Streamable HTTP sur /mcp. homeswift mcp lui relaie un client stdio.",
              "Run the MCP server": "Lancer le serveur MCP",
              "Lets Claude Desktop and other MCP clients read and control the bridge with a token.": "Permet à Claude Desktop et aux autres clients MCP de lire et contrôler le pont avec un jeton.",
              "Listen on": "Écouter sur",
              "The address it listens on: 127.0.0.1 (the default) keeps it to this machine, 0.0.0.0 opens it to your network.": "L'adresse où il écoute : 127.0.0.1 (par défaut) le limite à cette machine, 0.0.0.0 l'ouvre à votre réseau.",
              "Port": "Port",
              "The port of its /mcp address.": "Le port de son adresse /mcp.",
              "Admin token": "Jeton admin",
              "Admin": "Admin",
              "The main client's token, with admin access; the server needs one. homeswift mcp --generate-token makes one.": "Le jeton du client principal, avec l'accès admin ; le serveur en a besoin. homeswift mcp --generate-token en crée un.",
              "Read only": "Lecture seule",
              "Read": "Lecture",
              "Caps every token at read access.": "Limite chaque jeton à l'accès en lecture.",
              "Allowed browser origins": "Origines de navigateur autorisées",
              "Web pages allowed to call it from a browser, besides localhost and the server's own address, as https://example.com; * allows any.": "Les pages web autorisées à l'appeler depuis un navigateur, en plus de localhost et de l'adresse du serveur, sous la forme https://example.com ; * les autorise toutes.",
              "Audit log": "Journal d'audit",
              "Every write, with who asked, in homeswift-mcp-audit.jsonl.": "Chaque écriture, avec qui l'a demandée, dans homeswift-mcp-audit.jsonl.",
              "Audit log file": "Fichier du journal d'audit",
              "Where the audit log is written. Empty keeps it next to config.json.": "Où le journal d'audit est écrit. Vide : à côté de config.json.",
              "Client": "Client",
              "Clients": "Clients",
              "More tokens, each with its own access.": "D'autres jetons, chacun avec son propre accès.",
              "Name": "Nom",
              "Who uses this token, to tell the tokens apart.": "Qui utilise ce jeton, pour distinguer les jetons.",
              "The token this client sends.": "Le jeton que ce client envoie.",
              "Scope": "Portée",
              "Control": "Contrôle",
              "Read lists and reads; Control also sets accessories and runs scenes; Admin also changes the configuration and restarts.": "Lecture liste et lit ; Contrôle règle aussi les accessoires et lance les scènes ; Admin modifie aussi la configuration et redémarre.",
              "Answers": "Réponses"
            },
            "es": {
              "Provider": "Proveedor",
              "Anthropic (Claude)": "Anthropic (Claude)",
              "OpenAI": "OpenAI",
              "Google Gemini": "Google Gemini",
              "OpenAI-compatible (Ollama, LM Studio, a proxy)": "Compatible con OpenAI (Ollama, LM Studio, un proxy)",
              "Apple on-device model (macOS 26)": "Modelo de Apple en el dispositivo (macOS 26)",
              "Who answers. Apple's on-device model is free and private but too small for the chat's tools.": "Quién responde. El modelo de Apple en el dispositivo es gratuito y privado, pero demasiado pequeño para las herramientas del chat.",
              "Model": "Modelo",
              "The model's id, as the provider names it. Empty uses its default: claude-opus-5-5 for Claude, gpt-6.1-sol for OpenAI, gemini-3.8-flash for Gemini, llama3.1 on an OpenAI-compatible server.": "El id del modelo, como lo llama el proveedor. Vacío usa el predeterminado: claude-opus-5-5 para Claude, gpt-6.1-sol para OpenAI, gemini-3.8-flash para Gemini, llama3.1 en un servidor compatible con OpenAI.",
              "API key": "Clave de API",
              "Your key from the provider's console. Empty reads ANTHROPIC_API_KEY, OPENAI_API_KEY or GEMINI_API_KEY from the environment. Never sent anywhere but the provider.": "Tu clave, de la consola del proveedor. Vacío lee ANTHROPIC_API_KEY, OPENAI_API_KEY o GEMINI_API_KEY del entorno. Solo se envía al proveedor.",
              "Base URL": "URL base",
              "The server's OpenAI-compatible address, ending in /v1: Ollama's is http://127.0.0.1:11434/v1 (the default), LM Studio's http://127.0.0.1:1234/v1. Also a proxy in front of a provider.": "La dirección compatible con OpenAI del servidor, terminada en /v1: la de Ollama es http://127.0.0.1:11434/v1 (la predeterminada), la de LM Studio http://127.0.0.1:1234/v1. También un proxy delante de un proveedor.",
              "Effort": "Esfuerzo",
              "Low": "Baja",
              "Medium": "Medio",
              "High": "Alta",
              "Extra high": "Muy alta",
              "Max": "Máx.",
              "How long the model thinks before it answers (Claude, OpenAI's reasoning models): higher is more careful, slower and costs more. Empty leaves it to the model.": "Cuánto piensa el modelo antes de responder (Claude, los modelos de razonamiento de OpenAI): más alto es más cuidadoso, más lento y más caro. Vacío lo deja al modelo.",
              "Token": "Token",
              "Longest answer (tokens)": "Respuesta más larga (tokens)",
              "The most the Assistant writes in one answer, in tokens (a token is about three quarters of a word); a longer answer stops there.": "Lo máximo que el Asistente escribe en una respuesta, en tokens (un token es unas tres cuartas partes de una palabra); una respuesta más larga se corta ahí.",
              "Context window (tokens)": "Ventana de contexto (tokens)",
              "How much the model reads at once, for a local model the bridge cannot ask (8192 is assumed): what it is sent is trimmed to fit.": "Cuánto lee el modelo de una vez, para un modelo local al que el puente no puede preguntar (se supone 8192): lo que se le envía se recorta para que quepa.",
              "OpenAI API": "API de OpenAI",
              "Responses (OpenAI)": "Responses (OpenAI)",
              "Chat Completions (most local servers)": "Chat Completions (la mayoría de servidores locales)",
              "Which of OpenAI's APIs to call. Empty uses Responses for OpenAI and Chat Completions for a compatible server.": "Qué API de OpenAI llamar. Vacío usa Responses para OpenAI y Chat Completions para un servidor compatible.",
              "Retries": "Reintentos",
              "How many times a failed request is tried again (a timeout, a rate limit, a server error, the network). 0 never retries.": "Cuántas veces se reintenta una petición fallida (tiempo agotado, límite de frecuencia, error del servidor, la red). 0 no reintenta nunca.",
              "Prompt caching": "Caché de prompts",
              "Claude: keep the system prompt and tools in Anthropic's cache between requests, so they cost less and answer sooner. Turn it off for a proxy that rejects it.": "Claude: guarda el prompt del sistema y las herramientas en la caché de Anthropic entre peticiones, para que cuesten menos y respondan antes. Desactívalo para un proxy que lo rechace.",
              "Fallback model": "Modelo de respaldo",
              "Claude: when the model declines a request, let the API run it again on a fallback model. On by default for Opus 5.5, Opus 5, Sonnet 5.5 and Fable.": "Claude: cuando el modelo rechaza una petición, deja que la API la repita con un modelo de respaldo. Activado por defecto para Opus 5.5, Opus 5, Sonnet 5.5 y Fable.",
              "Enabled": "Activado",
              "Off keeps these settings but turns the Assistant off everywhere, until it is on again.": "Desactivado conserva estos ajustes pero apaga el Asistente en todas partes, hasta que vuelvas a activarlo.",
              "Budget": "Presupuesto",
              "Limits per day and per month, local time: once one is used up, requests are refused until it resets. Empty is no limit.": "Límites por día y por mes, en hora local: cuando se agota uno, las peticiones se rechazan hasta que se reinicia. Vacío es sin límite.",
              "Tokens per day": "Tokens al día",
              "Tokens the Assistant may use each day, what it reads and what it writes together. Empty is no limit.": "Tokens que el Asistente puede usar cada día, lo que lee y lo que escribe juntos. Vacío es sin límite.",
              "Tokens per month": "Tokens al mes",
              "The same, for each month.": "Lo mismo, para cada mes.",
              "USD per day": "USD al día",
              "The most it may spend each day, in US dollars. Only Claude models are priced: the others count as free.": "Lo máximo que puede gastar cada día, en dólares estadounidenses. Solo los modelos Claude tienen precio: los demás cuentan como gratuitos.",
              "USD per month": "USD al mes",
              "MCP server": "Servidor MCP",
              "Lets Claude Desktop, Claude Code, Cursor and other MCP clients list and set accessories, read the log and change config.json.": "Permite a Claude Desktop, Claude Code, Cursor y otros clientes MCP listar y ajustar los accesorios, leer el registro y cambiar config.json.",
              "Over HTTP": "Por HTTP",
              "The server inside the running bridge, over Streamable HTTP at /mcp. homeswift mcp forwards a stdio client to it.": "El servidor dentro del puente en marcha, por Streamable HTTP en /mcp. homeswift mcp le reenvía un cliente stdio.",
              "Run the MCP server": "Ejecutar el servidor MCP",
              "Lets Claude Desktop and other MCP clients read and control the bridge with a token.": "Permite a Claude Desktop y otros clientes MCP leer y controlar el puente con un token.",
              "Listen on": "Escuchar en",
              "The address it listens on: 127.0.0.1 (the default) keeps it to this machine, 0.0.0.0 opens it to your network.": "La dirección en la que escucha: 127.0.0.1 (la predeterminada) lo limita a esta máquina, 0.0.0.0 lo abre a tu red.",
              "Port": "Puerto",
              "The port of its /mcp address.": "El puerto de su dirección /mcp.",
              "Admin token": "Token de admin",
              "Admin": "Admin",
              "The main client's token, with admin access; the server needs one. homeswift mcp --generate-token makes one.": "El token del cliente principal, con acceso de admin; el servidor necesita uno. homeswift mcp --generate-token crea uno.",
              "Read only": "Solo lectura",
              "Read": "Lectura",
              "Caps every token at read access.": "Limita cada token al acceso de lectura.",
              "Allowed browser origins": "Orígenes de navegador permitidos",
              "Web pages allowed to call it from a browser, besides localhost and the server's own address, as https://example.com; * allows any.": "Páginas web que pueden llamarlo desde un navegador, además de localhost y la dirección del propio servidor, como https://example.com; * permite cualquiera.",
              "Audit log": "Registro de auditoría",
              "Every write, with who asked, in homeswift-mcp-audit.jsonl.": "Cada escritura, con quién la pidió, en homeswift-mcp-audit.jsonl.",
              "Audit log file": "Archivo del registro de auditoría",
              "Where the audit log is written. Empty keeps it next to config.json.": "Dónde se escribe el registro de auditoría. Vacío lo deja junto a config.json.",
              "Client": "Cliente",
              "Clients": "Clientes",
              "More tokens, each with its own access.": "Más tokens, cada uno con su propio acceso.",
              "Name": "Nombre",
              "Who uses this token, to tell the tokens apart.": "Quién usa este token, para distinguir los tokens.",
              "The token this client sends.": "El token que envía este cliente.",
              "Scope": "Ámbito",
              "Control": "Control",
              "Read lists and reads; Control also sets accessories and runs scenes; Admin also changes the configuration and restarts.": "Lectura lista y lee; Control también ajusta accesorios y ejecuta escenas; Admin también cambia la configuración y reinicia.",
              "Answers": "Respuestas"
            },
            "pt": {
              "Provider": "Fornecedor",
              "Anthropic (Claude)": "Anthropic (Claude)",
              "OpenAI": "OpenAI",
              "Google Gemini": "Google Gemini",
              "OpenAI-compatible (Ollama, LM Studio, a proxy)": "Compatível com OpenAI (Ollama, LM Studio, um proxy)",
              "Apple on-device model (macOS 26)": "Modelo da Apple no dispositivo (macOS 26)",
              "Who answers. Apple's on-device model is free and private but too small for the chat's tools.": "Quem responde. O modelo da Apple no dispositivo é gratuito e privado, mas demasiado pequeno para as ferramentas do chat.",
              "Model": "Modelo",
              "The model's id, as the provider names it. Empty uses its default: claude-opus-5-5 for Claude, gpt-6.1-sol for OpenAI, gemini-3.8-flash for Gemini, llama3.1 on an OpenAI-compatible server.": "O id do modelo, como o fornecedor o designa. Vazio usa o predefinido: claude-opus-5-5 para Claude, gpt-6.1-sol para OpenAI, gemini-3.8-flash para Gemini, llama3.1 num servidor compatível com OpenAI.",
              "API key": "Chave de API",
              "Your key from the provider's console. Empty reads ANTHROPIC_API_KEY, OPENAI_API_KEY or GEMINI_API_KEY from the environment. Never sent anywhere but the provider.": "A chave, obtida na consola do fornecedor. Vazio lê ANTHROPIC_API_KEY, OPENAI_API_KEY ou GEMINI_API_KEY do ambiente. Só é enviada ao fornecedor.",
              "Base URL": "URL base",
              "The server's OpenAI-compatible address, ending in /v1: Ollama's is http://127.0.0.1:11434/v1 (the default), LM Studio's http://127.0.0.1:1234/v1. Also a proxy in front of a provider.": "O endereço compatível com OpenAI do servidor, terminado em /v1: o do Ollama é http://127.0.0.1:11434/v1 (o predefinido), o do LM Studio http://127.0.0.1:1234/v1. Também um proxy à frente de um fornecedor.",
              "Effort": "Esforço",
              "Low": "Baixa",
              "Medium": "Médio",
              "High": "Alta",
              "Extra high": "Muito alta",
              "Max": "Máx.",
              "How long the model thinks before it answers (Claude, OpenAI's reasoning models): higher is more careful, slower and costs more. Empty leaves it to the model.": "Quanto tempo o modelo pensa antes de responder (Claude, os modelos de raciocínio da OpenAI): mais alto é mais cuidadoso, mais lento e mais caro. Vazio deixa a decisão ao modelo.",
              "Token": "Token",
              "Longest answer (tokens)": "Resposta mais longa (tokens)",
              "The most the Assistant writes in one answer, in tokens (a token is about three quarters of a word); a longer answer stops there.": "O máximo que o Assistente escreve numa resposta, em tokens (um token é cerca de três quartos de uma palavra); uma resposta mais longa para aí.",
              "Context window (tokens)": "Janela de contexto (tokens)",
              "How much the model reads at once, for a local model the bridge cannot ask (8192 is assumed): what it is sent is trimmed to fit.": "Quanto o modelo lê de uma vez, para um modelo local que a ponte não consegue consultar (assume-se 8192): o que lhe é enviado é cortado para caber.",
              "OpenAI API": "API da OpenAI",
              "Responses (OpenAI)": "Responses (OpenAI)",
              "Chat Completions (most local servers)": "Chat Completions (a maioria dos servidores locais)",
              "Which of OpenAI's APIs to call. Empty uses Responses for OpenAI and Chat Completions for a compatible server.": "Que API da OpenAI chamar. Vazio usa Responses para a OpenAI e Chat Completions para um servidor compatível.",
              "Retries": "Novas tentativas",
              "How many times a failed request is tried again (a timeout, a rate limit, a server error, the network). 0 never retries.": "Quantas vezes um pedido falhado é repetido (tempo esgotado, limite de pedidos, erro do servidor, a rede). 0 nunca repete.",
              "Prompt caching": "Cache de prompts",
              "Claude: keep the system prompt and tools in Anthropic's cache between requests, so they cost less and answer sooner. Turn it off for a proxy that rejects it.": "Claude: manter o prompt de sistema e as ferramentas na cache da Anthropic entre pedidos, para custarem menos e responderem mais depressa. Desativar para um proxy que o rejeite.",
              "Fallback model": "Modelo alternativo",
              "Claude: when the model declines a request, let the API run it again on a fallback model. On by default for Opus 5.5, Opus 5, Sonnet 5.5 and Fable.": "Claude: quando o modelo recusa um pedido, deixar a API repeti-lo num modelo alternativo. Ativado por predefinição para Opus 5.5, Opus 5, Sonnet 5.5 e Fable.",
              "Enabled": "Ativado",
              "Off keeps these settings but turns the Assistant off everywhere, until it is on again.": "Desativado mantém estas definições mas desliga o Assistente em todo o lado, até ser novamente ativado.",
              "Budget": "Orçamento",
              "Limits per day and per month, local time: once one is used up, requests are refused until it resets. Empty is no limit.": "Limites por dia e por mês, na hora local: quando um se esgota, os pedidos são recusados até ser reposto. Vazio é sem limite.",
              "Tokens per day": "Tokens por dia",
              "Tokens the Assistant may use each day, what it reads and what it writes together. Empty is no limit.": "Tokens que o Assistente pode usar por dia, o que lê e o que escreve somados. Vazio é sem limite.",
              "Tokens per month": "Tokens por mês",
              "The same, for each month.": "O mesmo, para cada mês.",
              "USD per day": "USD por dia",
              "The most it may spend each day, in US dollars. Only Claude models are priced: the others count as free.": "O máximo que pode gastar por dia, em dólares americanos. Só os modelos Claude têm preço: os outros contam como gratuitos.",
              "USD per month": "USD por mês",
              "MCP server": "Servidor MCP",
              "Lets Claude Desktop, Claude Code, Cursor and other MCP clients list and set accessories, read the log and change config.json.": "Permite ao Claude Desktop, ao Claude Code, ao Cursor e a outros clientes MCP listar e definir os acessórios, ler o registo e alterar o config.json.",
              "Over HTTP": "Por HTTP",
              "The server inside the running bridge, over Streamable HTTP at /mcp. homeswift mcp forwards a stdio client to it.": "O servidor dentro da ponte em execução, por Streamable HTTP em /mcp. homeswift mcp reencaminha-lhe um cliente stdio.",
              "Run the MCP server": "Executar o servidor MCP",
              "Lets Claude Desktop and other MCP clients read and control the bridge with a token.": "Permite ao Claude Desktop e a outros clientes MCP ler e controlar a ponte com um token.",
              "Listen on": "Escutar em",
              "The address it listens on: 127.0.0.1 (the default) keeps it to this machine, 0.0.0.0 opens it to your network.": "O endereço em que escuta: 127.0.0.1 (o predefinido) limita-o a esta máquina, 0.0.0.0 abre-o à rede.",
              "Port": "Porta",
              "The port of its /mcp address.": "A porta do seu endereço /mcp.",
              "Admin token": "Token de admin",
              "Admin": "Admin",
              "The main client's token, with admin access; the server needs one. homeswift mcp --generate-token makes one.": "O token do cliente principal, com acesso de admin; o servidor precisa de um. homeswift mcp --generate-token cria um.",
              "Read only": "Só leitura",
              "Read": "Leitura",
              "Caps every token at read access.": "Limita cada token ao acesso de leitura.",
              "Allowed browser origins": "Origens de navegador permitidas",
              "Web pages allowed to call it from a browser, besides localhost and the server's own address, as https://example.com; * allows any.": "Páginas web autorizadas a chamá-lo a partir de um navegador, além de localhost e do endereço do próprio servidor, como https://example.com; * permite qualquer uma.",
              "Audit log": "Registo de auditoria",
              "Every write, with who asked, in homeswift-mcp-audit.jsonl.": "Cada escrita, com quem a pediu, em homeswift-mcp-audit.jsonl.",
              "Audit log file": "Ficheiro do registo de auditoria",
              "Where the audit log is written. Empty keeps it next to config.json.": "Onde o registo de auditoria é escrito. Vazio mantém-no junto ao config.json.",
              "Client": "Cliente",
              "Clients": "Clientes",
              "More tokens, each with its own access.": "Mais tokens, cada um com o seu próprio acesso.",
              "Name": "Nome",
              "Who uses this token, to tell the tokens apart.": "Quem usa este token, para distinguir os tokens.",
              "The token this client sends.": "O token que este cliente envia.",
              "Scope": "Âmbito",
              "Control": "Controlo",
              "Read lists and reads; Control also sets accessories and runs scenes; Admin also changes the configuration and restarts.": "Leitura lista e lê; Controlo também define acessórios e executa cenas; Admin também altera a configuração e reinicia.",
              "Answers": "Respostas"
            }
          }
        }
        """#

    public var name: String
    public var enabled: Bool
    public var provider: ProviderKind
    public var model: String
    /// Secret: redaction treats it as one.
    public var apiKey: String?
    public var baseURL: String?
    public var maxOutputTokens: Int
    /// Overrides the provider's context window, e.g. for a local model.
    public var contextTokens: Int?
    public var effort: EffortLevel?
    public var openaiAPI: OpenAIAPI?
    /// Retries of a failed provider request; default 2, 0 disables.
    public var maxRetries: Int
    /// Claude: cache breakpoints on the system prompt and tools (default true; off for proxies that reject them).
    public var promptCaching: Bool
    /// Claude Opus 5.5, Opus 5, Sonnet 5.5 and Fable: let the API re-run a declined request on a fallback
    /// model (default true for those models).
    public var fallbacks: Bool?
    /// Daily and monthly limits (`budget`: `dailyTokens`, `monthlyTokens`, `dailyUsd`, `monthlyUsd`).
    public var budget = UsageBudget()
    /// Whether the block (or the environment) names a provider or a key at all. A block that only turns
    /// on the MCP server has neither, and then no Assistant is set up.
    public var hasProviderSettings = true

    public init(provider: ProviderKind, model: String? = nil, apiKey: String? = nil, name: String = "AI Kit", enabled: Bool = true) {
        self.name = name
        self.enabled = enabled
        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.apiKey = apiKey
        maxOutputTokens = Self.defaultMaxOutputTokens
        maxRetries = 2
        promptCaching = true
    }

    /// Reads a block, applying defaults. Unknown providers, efforts and APIs, and bad numbers, throw.
    public init(block: JSONValue, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let object = block.objectValue ?? [:]
        func string(_ key: String) -> String? {
            object[key]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty
        }
        func positiveInt(_ key: String) throws -> Int? {
            guard let value = object[key], !value.isNull else { return nil }
            guard let int = value.intValue ?? value.stringValue.flatMap(Int.init), int > 0 else {
                throw AIConfigurationError.invalid(key: key, expected: "a positive integer")
            }
            return int
        }
        let providerName = string("provider") ?? ProviderKind.anthropic.rawValue
        guard let provider = ProviderKind(rawValue: providerName) else {
            throw AIConfigurationError.invalid(key: "provider", expected: "one of \(ProviderKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        self.provider = provider
        name = string("name") ?? "AI Kit"
        enabled = object["enabled"] != .bool(false)
        model = string("model") ?? provider.defaultModel
        apiKey = string("apiKey") ?? provider.apiKeyEnvironmentVariable.flatMap { environment[$0]?.nonEmpty }
        baseURL = string("baseUrl").map { $0.replacingOccurrences(of: "/+$", with: "", options: .regularExpression) }
        maxOutputTokens = try positiveInt("maxOutputTokens") ?? Self.defaultMaxOutputTokens
        contextTokens = try positiveInt("contextTokens")
        if let effort = string("effort") {
            guard let level = EffortLevel(rawValue: effort) else {
                throw AIConfigurationError.invalid(key: "effort", expected: "one of \(EffortLevel.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            self.effort = level
        }
        if let api = string("openaiApi") {
            guard let value = OpenAIAPI(rawValue: api) else { throw AIConfigurationError.invalid(key: "openaiApi", expected: "responses or chat") }
            openaiAPI = value
        }
        if let retries = object["maxRetries"], !retries.isNull {
            guard let int = retries.intValue, int >= 0 else { throw AIConfigurationError.invalid(key: "maxRetries", expected: "a non-negative integer") }
            maxRetries = int
        } else {
            maxRetries = 2
        }
        promptCaching = object["promptCaching"] != .bool(false)
        fallbacks = object["fallbacks"]?.boolValue
        budget = try UsageBudget(json: object["budget"])
        hasProviderSettings = object["provider"] != nil || object["model"] != nil || apiKey != nil
    }

    /// The provider adapter this configuration selects.
    public func makeProvider(transport: any HTTPTransport = URLSessionTransport()) throws -> any Provider {
        switch provider {
        case .anthropic:
            return try AnthropicProvider(configuration: self, transport: transport)
        case .openai, .openaiCompatible:
            return try OpenAIProvider(configuration: self, transport: transport)
        case .gemini:
            return try GeminiProvider(configuration: self, transport: transport)
        case .apple:
            return try AppleProvider.make(configuration: self)
        }
    }
}

public enum AIConfigurationError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalid(key: String, expected: String)
    case missingAPIKey(provider: String, environmentVariable: String?)
    case unavailable(String)

    public var description: String {
        switch self {
        case .invalid(let key, let expected): "HomeswiftAiKit: \"\(key)\" must be \(expected)"
        case .missingAPIKey(let provider, let variable):
            "HomeswiftAiKit: \(provider) needs an API key: set \"apiKey\" in the block\(variable.map { " or \($0) in the environment" } ?? "")"
        case .unavailable(let reason): "HomeswiftAiKit: \(reason)"
        }
    }
}

extension String {
    public var nonEmpty: String? { isEmpty ? nil : self }
}

extension JSONValue {
    /// A port from a number or a numeric string, 1 to 65535.
    public var portValue: Int? {
        guard let value = intValue ?? stringValue.flatMap(Int.init), (1...65535).contains(value) else { return nil }
        return value
    }
}
