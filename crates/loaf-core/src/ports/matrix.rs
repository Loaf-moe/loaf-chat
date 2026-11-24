/// What a homeserver's login endpoint and OAuth metadata offered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerOffer {
    /// The server publishes OAuth 2.0 metadata.
    pub oauth: bool,
    /// `m.login.sso` is offered: `None` when it isn't, an empty list when it
    /// is offered without naming providers.
    pub sso: Option<Vec<IdentityProvider>>,
    /// `m.login.password` is offered.
    pub password: bool,
}

/// One single sign-on provider a server lists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IdentityProvider {
    pub id: String,
    pub name: Option<String>,
}
