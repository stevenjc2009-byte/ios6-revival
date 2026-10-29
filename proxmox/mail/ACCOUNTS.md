# Account setup: Google, Microsoft, iCloud, Yahoo

Gmail and Outlook/Hotmail go through the bridge ([README.md](README.md)) and need an OAuth client that you create
once, in your own browser, in your own Google/Microsoft account. iCloud and Yahoo need nothing: skip to the end.

Nothing here puts a secret in the repo. The client ID/secret you get are typed into `install.sh` and live only in
`/etc/mailproxy/emailproxy.config` inside the container.

---

## Google (Gmail): Cloud Console OAuth client

Why a client of your own: the proxy's author does not ship one (Google would have to verify it for `mail.google.com`),
so you make a private one for your own mailbox.

1. Go to <https://console.cloud.google.com/> and sign in with the Google account you want the project under
   (can be the Gmail account itself). Accept the terms if asked.
2. Project picker (top bar) > **New project**. Name: `ios6-mail-bridge`. Create, then select it.
3. **No API needs enabling.** IMAP/SMTP are not APIs in the Cloud sense; the Gmail API is not used.
4. Menu > **APIs & Services > OAuth consent screen** (newer console: **Google Auth Platform**). Click **Get started**.
   - App name `ios6-mail-bridge`, support email your own. Next.
   - Audience: **External**. (Internal exists only for Google Workspace organisations.) Next.
   - Contact email: your own. Agree to the policy, Create.
5. **Data Access** (or "Scopes") > **Add or remove scopes** > in "Manually add scopes" paste
   `https://mail.google.com/` > Add to table > Update > Save. (It is a "restricted" scope; for your own use that only means the
   warning screen later.)
6. **Publishing status. This is the important step.** Under **Audience** (or on the consent screen page) the status
   starts as **Testing**. Click **Publish app** > Confirm, so it reads **In production**.
   - While **Testing**, Google issues refresh tokens that **expire after 7 days**: the bridge would stop working weekly
     and need a fresh `mail-authorise`.
   - **In production** removes that 7-day limit. You do **not** have to submit for verification: an unverified
     production app is capped at 100 users and shows an "unverified app" warning at sign-in, which is fine for a
     private app used by you. Clicking **Advanced > Go to ios6-mail-bridge (unsafe)** at sign-in is expected.
   - Source (Google, "Refresh token expiration"): <https://developers.google.com/identity/protocols/oauth2#expiration>
     says "a publishing status of 'Testing' is issued a refresh token expiring in 7 days". The same page lists the
     other ways a token dies: you revoke it; **six months** without use; you change your Google password while the token
     has Gmail scopes (re-run `mail-authorise --reset`); more than the maximum number of live tokens per account/client
     (100); an admin restricts the scope. Consent-screen help: <https://support.google.com/cloud/answer/10311615>.
   - Verified in the documentation, **not** tested against a live account here: confirm the page shows "In production"
     and re-check in a week that the bridge still works.
7. **Clients** (or **Credentials > Create credentials > OAuth client ID**): Application type **Desktop app**, name
   `ios6-mail-bridge`, Create. Copy the **Client ID** and **Client secret** (or download the JSON and read them from
   it, then delete the JSON). A Desktop client allows `http://localhost` redirects, which is what the paste step in
   `mail-authorise` uses. (Do not choose "Web application": it needs registered redirect URIs.)
8. Enter the Client ID/secret at the installer prompt. Account address = your Gmail address.

Gmail itself: IMAP is always on for modern Gmail accounts (the old "Enable IMAP" switch is gone). If a Google
Workspace admin blocks "less secure apps"/IMAP, that is theirs to allow. Two-step verification may stay on: OAuth
sign-in happens in your own browser, and the phone never sees your Google password.

---

## Microsoft (Outlook.com / Hotmail / Live): Entra app registration

Microsoft supports OAuth for IMAP/SMTP for **both Microsoft 365 and Outlook.com** accounts (Microsoft Learn,
<https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth>).
Basic auth (just a password) on outlook.com IMAP is gone, so OAuth is the only way.

Microsoft requires every app, even your own private one, to be registered in Entra (formerly Azure AD).

1. Go to <https://entra.microsoft.com/> and sign in with the Microsoft account you want to use. A registration needs a
   directory: if your personal account has none, Microsoft prompts you to create one (a free Azure account with
   no resources). Microsoft changes this step often and I could not test it; a free Microsoft 365 Developer tenant is an
   alternative.
2. **App registrations > New registration**.
   - Name: `ios6-mail-bridge`.
   - Supported account types: **Accounts in any organizational directory (Any Microsoft Entra ID tenant -
     Multitenant) and personal Microsoft accounts (such as Skype, Xbox)**. Personal Outlook/Hotmail addresses
     **only work with this option**; the "this directory only" choice rejects them.
   - Redirect URI: platform **Public client/native (mobile & desktop)**, value `http://localhost`.
   - Register. Copy the **Application (client) ID** from the overview page.
3. **Authentication**: confirm the platform "Mobile and desktop applications" lists `http://localhost`. Under **Advanced
   settings**, **Allow public client flows = Yes**. Save.
4. **API permissions > Add a permission > APIs my organization uses**, search `Office 365 Exchange Online`, choose
   **Delegated permissions**, tick `IMAP.AccessAsUser.All` and `SMTP.Send`, Add. Then **Add a permission > Microsoft
   Graph > Delegated permissions > OpenId permissions** and tick **`offline_access`** (it makes Microsoft issue
   refresh tokens). No admin consent is needed for your own personal account; you consent at first sign-in.
5. **Client secret: optional.** A public client needs none; leave the installer's secret prompt empty. Only if the
   token step later fails with `AADSTS7000218`, add one under **Certificates & secrets > New client secret** (copy the
   *Value*, not the ID) and give it to the installer / put `client_secret = ...` in the account section.
6. Enter the client ID at the installer prompt. Account address = your Outlook/Hotmail address.

Scopes used by the bridge (full strings, Microsoft requires the resource URL):
`https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access`.
Endpoints: `https://login.microsoftonline.com/common/oauth2/v2.0/authorize` and `.../token` (`/common/` covers both
personal and work accounts). Servers: IMAP `outlook.office365.com:993`, SMTP `smtp-mail.outlook.com:587` (STARTTLS).

Refresh tokens for personal accounts last ~90 days of **inactivity**, and renew every time the bridge uses them.

---

## Removing access later

- Google: <https://myaccount.google.com/permissions> > `ios6-mail-bridge` > Delete all connections. Then delete the
  Cloud project if you like.
- Microsoft: <https://account.live.com/consent/Manage> > the app > Remove these permissions. Then delete the app registration.
- On the box: `pct destroy` through `uninstall.sh` removes the stored tokens and client secret.

---

## iCloud Mail: no server needed

Type it straight into iOS 6 Mail; Apple's server speaks SSL password auth. You need an **app-specific password**
(requires two-factor authentication on the Apple Account): <https://account.apple.com/> > Sign-In and Security >
App-Specific Passwords > Generate. Use that, **not** your Apple Account password. Settings from Apple
(<https://support.apple.com/en-us/102525>):

| | Incoming (IMAP) | Outgoing (SMTP) |
|---|---|---|
| Host name | `imap.mail.me.com` | `smtp.mail.me.com` |
| User name | the part before `@icloud.com` (if that fails, the full address) | full address `you@icloud.com` |
| Password | app-specific password | same app-specific password |
| Use SSL | **ON** | **ON** |
| Port | **993** | **587** |
| Authentication | Password | Password |

Port 587 with "Use SSL" ON is STARTTLS in iOS Mail. Apple's doc adds: if SSL errors, try TLS/STARTTLS wording. Add via
Settings > Mail, Contacts, Calendars > Add Account > Other > Add Mail Account > IMAP, then Advanced for the port/SSL.

## Yahoo Mail: no server needed

Create an **app password** (Yahoo Account Security > Generate app password; two-step verification must be on):
<https://login.yahoo.com/account/security>. Settings from Yahoo (<https://help.yahoo.com/kb/SLN4075.html>):

| | Incoming (IMAP) | Outgoing (SMTP) |
|---|---|---|
| Host name | `imap.mail.yahoo.com` | `smtp.mail.yahoo.com` |
| User name | full address `you@yahoo.com` | full address |
| Password | app password | app password |
| Use SSL | **ON** | **ON** |
| Port | **993** | **465** (587 also works) |
| Authentication | Password | Password |

**Not tested on a real iOS 6 device** for iCloud or Yahoo: iOS 6 only has TLS up to 1.2 with older ciphers and an old
root-certificate store. If Mail says it cannot verify the server identity or "cannot connect using SSL", that is the
phone's limit and there is no fix on the server side; say so and the bridge can be extended to relay these too.
