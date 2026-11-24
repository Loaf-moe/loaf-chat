use url::Url;

use crate::ports::matrix::ServerOffer;

/// The ways to sign in that a server offers, in the order to show them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthMethods {
    pub browser: Vec<BrowserMethod>,
    pub password: bool,
}

/// A sign-in that happens in the system browser.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BrowserMethod {
    OAuth,
    /// `provider` is the id sent to the server; `None` when the server lists
    /// no providers. `name` is what the person sees.
    Sso {
        provider: Option<String>,
        name: Option<String>,
    },
}

/// The host (with any port, lowercased) in a server name, URL or full user id,
/// or `None` while the input isn't a plausible host yet.
#[cfg_attr(not(test), expect(dead_code, reason = "used from Task 5"))]
pub(crate) fn parse_server(input: &str) -> Option<String> {
    let trimmed = input.trim();
    if trimmed.starts_with('@') {
        return user_id_server(trimmed);
    }
    host_with_port(trimmed)
}

/// The server named by a full user id typed into the username field, so a
/// plain username leaves the server alone.
#[cfg_attr(not(test), expect(dead_code, reason = "used from Task 5"))]
pub(crate) fn user_id_server(text: &str) -> Option<String> {
    let rest = text.trim().strip_prefix('@')?;
    let (_localpart, server) = rest.split_once(':')?;
    host_with_port(server)
}

/// Goes through `Url` so half-typed input can't become an error: whatever it
/// rejects, or that isn't a plausible host yet, is `None`.
fn host_with_port(text: &str) -> Option<String> {
    if text.is_empty() || text.chars().any(char::is_whitespace) {
        return None;
    }
    let with_scheme;
    let candidate = if text.contains("://") {
        text
    } else {
        with_scheme = format!("https://{text}");
        &with_scheme
    };
    let url = Url::parse(candidate).ok()?;
    let host = url.host_str()?.to_lowercase();
    if !(host.contains('.') || host == "localhost") {
        return None;
    }
    Some(match url.port() {
        Some(port) => format!("{host}:{port}"),
        None => host,
    })
}

/// OAuth is the one browser method when published; otherwise SSO, one per
/// provider in the server's order.
#[cfg_attr(not(test), expect(dead_code, reason = "used from Task 5"))]
pub(crate) fn auth_methods(offer: &ServerOffer) -> AuthMethods {
    let browser = if offer.oauth {
        vec![BrowserMethod::OAuth]
    } else {
        match &offer.sso {
            None => Vec::new(),
            Some(providers) if providers.is_empty() => vec![BrowserMethod::Sso {
                provider: None,
                name: None,
            }],
            Some(providers) => providers
                .iter()
                .map(|provider| BrowserMethod::Sso {
                    provider: Some(provider.id.clone()),
                    name: Some(provider.name.clone().unwrap_or_else(|| provider.id.clone())),
                })
                .collect(),
        }
    };
    AuthMethods {
        browser,
        password: offer.password,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ports::matrix::IdentityProvider;

    #[test]
    fn names_urls_and_user_ids_give_the_host() {
        for (input, host) in [
            ("loaf.moe", "loaf.moe"),
            ("https://loaf.moe/", "loaf.moe"),
            ("https://matrix.loaf.moe:8448/path", "matrix.loaf.moe:8448"),
            ("@alice:Loaf.Moe", "loaf.moe"),
            ("  LOAF.moe ", "loaf.moe"),
            ("localhost:8008", "localhost:8008"),
        ] {
            assert_eq!(parse_server(input).as_deref(), Some(host), "{input:?}");
        }
    }

    #[test]
    fn implausible_input_gives_nothing() {
        for input in ["", "loaf", "loaf moe", "@alice", "https://"] {
            assert_eq!(parse_server(input), None, "{input:?}");
        }
    }

    #[test]
    fn every_prefix_is_none_or_plausible() {
        for full in ["https://matrix.loaf.moe:8448", "@alice:loaf.moe"] {
            for end in 0..=full.len() {
                let Some(prefix) = full.get(..end) else {
                    continue;
                };
                if let Some(host) = parse_server(prefix) {
                    assert!(
                        host.contains('.') || host.starts_with("localhost"),
                        "{prefix:?} gave {host:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn user_id_server_only_for_full_ids() {
        assert_eq!(user_id_server("@bob:example.org").as_deref(), Some("example.org"));
        for text in ["bob", "@bob", "@bob:"] {
            assert_eq!(user_id_server(text), None, "{text:?}");
        }
    }

    fn provider(id: &str, name: Option<&str>) -> IdentityProvider {
        IdentityProvider {
            id: id.to_owned(),
            name: name.map(str::to_owned),
        }
    }

    #[test]
    fn oauth_hides_sso() {
        let offer = ServerOffer {
            oauth: true,
            sso: Some(vec![provider("a", None), provider("b", None)]),
            password: true,
        };
        let methods = auth_methods(&offer);
        assert_eq!(methods.browser, vec![BrowserMethod::OAuth]);
        assert!(methods.password);
    }

    #[test]
    fn sso_keeps_order_and_falls_back_to_id() {
        let offer = ServerOffer {
            oauth: false,
            sso: Some(vec![provider("gh", Some("GitHub")), provider("kanidm", None)]),
            password: false,
        };
        assert_eq!(
            auth_methods(&offer).browser,
            vec![
                BrowserMethod::Sso {
                    provider: Some("gh".into()),
                    name: Some("GitHub".into())
                },
                BrowserMethod::Sso {
                    provider: Some("kanidm".into()),
                    name: Some("kanidm".into())
                },
            ]
        );
    }

    #[test]
    fn sso_without_providers_is_one_method() {
        let offer = ServerOffer {
            oauth: false,
            sso: Some(Vec::new()),
            password: false,
        };
        assert_eq!(
            auth_methods(&offer).browser,
            vec![BrowserMethod::Sso {
                provider: None,
                name: None
            }]
        );
    }

    #[test]
    fn password_only_when_offered() {
        let mut offer = ServerOffer {
            oauth: false,
            sso: None,
            password: true,
        };
        assert!(auth_methods(&offer).password);
        offer.password = false;
        assert!(!auth_methods(&offer).password);
    }

    #[test]
    fn nothing_usable_is_empty() {
        let offer = ServerOffer {
            oauth: false,
            sso: None,
            password: false,
        };
        assert_eq!(
            auth_methods(&offer),
            AuthMethods {
                browser: Vec::new(),
                password: false
            }
        );
    }
}
