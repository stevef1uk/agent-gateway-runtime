# ZAP Scanning Report

ZAP by [Checkmarx](https://checkmarx.com/).


## Summary of Alerts

| Risk Level | Number of Alerts |
| --- | --- |
| High | 0 |
| Medium | 1 |
| Low | 0 |
| Informational | 4 |




## Insights

| Level | Reason | Site | Description | Statistic |
| --- | --- | --- | --- | --- |
| Info | Informational | https://testten1.preprod.agw.sjfisher.com | Percentage of responses with status code 2xx | 66 % |
| Info | Informational | https://testten1.preprod.agw.sjfisher.com | Percentage of responses with status code 3xx | 8 % |
| Info | Informational | https://testten1.preprod.agw.sjfisher.com | Percentage of responses with status code 4xx | 25 % |
| Info | Informational | https://testten1.preprod.agw.sjfisher.com | Percentage of endpoints with content type text/css | 10 % |
| Info | Informational | https://testten1.preprod.agw.sjfisher.com | Percentage of endpoints with content type text/html | 40 % |
| Info | Informational | https://testten1.preprod.agw.sjfisher.com | Percentage of endpoints with content type text/javascript | 20 % |
| Info | Informational | https://testten1.preprod.agw.sjfisher.com | Percentage of endpoints with content type text/plain | 20 % |
| Info | Informational | https://testten1.preprod.agw.sjfisher.com | Percentage of endpoints with method GET | 90 % |
| Info | Informational | https://testten1.preprod.agw.sjfisher.com | Percentage of endpoints with method POST | 10 % |
| Info | Informational | https://testten1.preprod.agw.sjfisher.com | Count of total endpoints | 10    |
| Info | Informational | https://testten1.preprod.agw.sjfisher.com | Percentage of slow responses | 8 % |







## Alerts

| Name | Risk Level | Number of Instances |
| --- | --- | --- |
| Absence of Anti-CSRF Tokens | Medium | 1 |
| Cookie Poisoning | Informational | 1 |
| Information Disclosure - Suspicious Comments | Informational | 5 |
| Re-examine Cache-control Directives | Informational | 3 |
| Session Management Response Identified | Informational | 1 |




## Alert Detail



### [ Absence of Anti-CSRF Tokens ](https://www.zaproxy.org/docs/alerts/10202/)



##### Medium (Low)

### Description

No Anti-CSRF tokens were found in a HTML submission form.
A cross-site request forgery is an attack that involves forcing a victim to send an HTTP request to a target destination without their knowledge or intent in order to perform an action as the victim. The underlying cause is application functionality using predictable URL/form actions in a repeatable way. The nature of the attack is that CSRF exploits the trust that a web site has for a user. By contrast, cross-site scripting (XSS) exploits the trust that a user has for a web site. Like XSS, CSRF attacks are not necessarily cross-site, but they can be. Cross-site request forgery is also known as CSRF, XSRF, one-click attack, session riding, confused deputy, and sea surf.

CSRF attacks are effective in a number of situations, including:
    * The victim has an active session on the target site.
    * The victim is authenticated via HTTP auth on the target site.
    * The victim is on the same local network as the target site.

CSRF has primarily been used to perform an action against a target site using the victim's privileges, but recent techniques have been discovered to disclose information by gaining access to the response. The risk of information disclosure is dramatically increased when the target site is vulnerable to XSS, because XSS can be used as a platform for CSRF, allowing the attack to operate within the bounds of the same-origin policy.

* URL: https://testten1.preprod.agw.sjfisher.com/signup.html
  * Node Name: `https://testten1.preprod.agw.sjfisher.com/signup.html`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `<form id="signupForm" method="post">`
  * Other Info: `No known Anti-CSRF token [anticsrf, CSRFToken, __RequestVerificationToken, csrfmiddlewaretoken, authenticity_token, OWASP_CSRFTOKEN, anoncsrf, csrf_token, _csrf, _csrfSecret, __csrf_magic, CSRF, _token, _csrf_token, _csrfToken] was found in the following HTML form: [Form 1: "signup_company" "signup_email" "signup_name" ].`


Instances: 1

### Solution

Phase: Architecture and Design
Use a vetted library or framework that does not allow this weakness to occur or provides constructs that make this weakness easier to avoid.
For example, use anti-CSRF packages such as the OWASP CSRFGuard.

Phase: Implementation
Ensure that your application is free of cross-site scripting issues, because most CSRF defenses can be bypassed using attacker-controlled script.

Phase: Architecture and Design
Generate a unique nonce for each form, place the nonce into the form, and verify the nonce upon receipt of the form. Be sure that the nonce is not predictable (CWE-330).
Note that this can be bypassed using XSS.

Identify especially dangerous operations. When the user performs a dangerous operation, send a separate confirmation request to ensure that the user intended to perform that operation.
Note that this can be bypassed using XSS.

Use the ESAPI Session Management control.
This control includes a component for CSRF.

Do not use the GET method for any request that triggers a state change.

Phase: Implementation
Check the HTTP Referer header to see if the request originated from an expected page. This could break legitimate functionality, because users or proxies may have disabled sending the Referer for privacy reasons.

### Reference


* [ https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html ](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html)
* [ https://cwe.mitre.org/data/definitions/352.html ](https://cwe.mitre.org/data/definitions/352.html)


#### CWE Id: [ 352 ](https://cwe.mitre.org/data/definitions/352.html)


#### WASC Id: 9

#### Source ID: 3

### [ Cookie Poisoning ](https://www.zaproxy.org/docs/alerts/10029/)



##### Informational (Low)

### Description

This check looks at user-supplied input in query string parameters and POST data to identify where cookie parameters might be controlled. This is called a cookie poisoning attack, and becomes exploitable when an attacker can manipulate the cookie in various ways. In some cases this will not be exploitable, however, allowing URL parameters to set cookie values is generally considered a bug.

* URL: https://testten1.preprod.agw.sjfisher.com/oidc/login%3Fprompt=select_account
  * Node Name: `https://testten1.preprod.agw.sjfisher.com/oidc/login (prompt)`
  * Method: `GET`
  * Parameter: `prompt`
  * Attack: ``
  * Evidence: ``
  * Other Info: `An attacker may be able to poison cookie values through URL parameters. Try injecting a semicolon to see if you can add cookie values (e.g. name=controlledValue;name=anotherValue;).

This was identified at:

https://testten1.preprod.agw.sjfisher.com/oidc/login?prompt=select_account

User-input was found in the following cookie:
oidc_prompt=select_account; Path=/; Max-Age=600; HttpOnly; Secure; SameSite=Lax

The user input was:
prompt=select_account`


Instances: 1

### Solution

Do not allow user input to control cookie names and values. If some query string parameters must be set in cookie values, be sure to filter out semicolon's that can serve as name/value pair delimiters.

### Reference


* [ https://en.wikipedia.org/wiki/HTTP_cookie ](https://en.wikipedia.org/wiki/HTTP_cookie)
* [ https://cwe.mitre.org/data/definitions/565.html ](https://cwe.mitre.org/data/definitions/565.html)


#### CWE Id: [ 565 ](https://cwe.mitre.org/data/definitions/565.html)


#### WASC Id: 20

#### Source ID: 3

### [ Information Disclosure - Suspicious Comments ](https://www.zaproxy.org/docs/alerts/10027/)



##### Informational (Medium)

### Description

The response appears to contain suspicious comments which may help an attacker.

* URL: https://testten1.preprod.agw.sjfisher.com/
  * Node Name: `https://testten1.preprod.agw.sjfisher.com/`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `<!-- URL Query / Search Parameters`
  * Other Info: `The following pattern was used: \bQUERY\b and was detected in likely comment: "<!-- URL Query / Search Parameters input -->", see evidence field for the suspicious comment/snippet.`
* URL: https://testten1.preprod.agw.sjfisher.com/%3Fsigned_in=1
  * Node Name: `https://testten1.preprod.agw.sjfisher.com/ (signed_in)`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `<!-- URL Query / Search Parameters`
  * Other Info: `The following pattern was used: \bQUERY\b and was detected in likely comment: "<!-- URL Query / Search Parameters input -->", see evidence field for the suspicious comment/snippet.`
* URL: https://testten1.preprod.agw.sjfisher.com/assets/index.js
  * Node Name: `https://testten1.preprod.agw.sjfisher.com/assets/index.js`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: ` present the Tenant Administrator Sign-In gate.`
  * Other Info: `The following pattern was used: \bADMINISTRATOR\b and was detected in likely comment: "// present the Tenant Administrator Sign-In gate.", see evidence field for the suspicious comment/snippet.`
* URL: https://testten1.preprod.agw.sjfisher.com/assets/index.js
  * Node Name: `https://testten1.preprod.agw.sjfisher.com/assets/index.js`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `// Identity comes from the server-side con`
  * Other Info: `The following pattern was used: \bFROM\b and was detected 3 times, the first in likely comment: "// Identity comes from the server-side console session: when signed in the", see evidence field for the suspicious comment/snippet.`
* URL: https://testten1.preprod.agw.sjfisher.com/assets/index.js
  * Node Name: `https://testten1.preprod.agw.sjfisher.com/assets/index.js`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `// a user name is sent only w`
  * Other Info: `The following pattern was used: \bUSER\b and was detected 5 times, the first in likely comment: "// a user name is sent only when there is no verified session (dev mode).", see evidence field for the suspicious comment/snippet.`


Instances: 5

### Solution

Remove all comments that return information that may help an attacker and fix any underlying problems they refer to.

### Reference



#### CWE Id: [ 615 ](https://cwe.mitre.org/data/definitions/615.html)


#### WASC Id: 13

#### Source ID: 3

### [ Re-examine Cache-control Directives ](https://www.zaproxy.org/docs/alerts/10015/)



##### Informational (Low)

### Description

The cache-control header has not been set properly or is missing, allowing the browser and proxies to cache content. For static assets like css, js, or image files this might be intended, however, the resources should be reviewed to ensure that no sensitive content will be cached.

* URL: https://testten1.preprod.agw.sjfisher.com/
  * Node Name: `https://testten1.preprod.agw.sjfisher.com/`
  * Method: `GET`
  * Parameter: `cache-control`
  * Attack: ``
  * Evidence: `no-cache`
  * Other Info: ``
* URL: https://testten1.preprod.agw.sjfisher.com/%3Fsigned_in=1
  * Node Name: `https://testten1.preprod.agw.sjfisher.com/ (signed_in)`
  * Method: `GET`
  * Parameter: `cache-control`
  * Attack: ``
  * Evidence: `no-cache`
  * Other Info: ``
* URL: https://testten1.preprod.agw.sjfisher.com/signup.html
  * Node Name: `https://testten1.preprod.agw.sjfisher.com/signup.html`
  * Method: `GET`
  * Parameter: `cache-control`
  * Attack: ``
  * Evidence: `no-cache`
  * Other Info: ``


Instances: 3

### Solution

For secure content, ensure the cache-control HTTP header is set with "no-cache, no-store, must-revalidate". If an asset should be cached consider setting the directives "public, max-age, immutable".

### Reference


* [ https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html#web-content-caching ](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html#web-content-caching)
* [ https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cache-Control ](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cache-Control)
* [ https://grayduck.mn/2021/09/13/cache-control-recommendations/ ](https://grayduck.mn/2021/09/13/cache-control-recommendations/)


#### CWE Id: [ 525 ](https://cwe.mitre.org/data/definitions/525.html)


#### WASC Id: 13

#### Source ID: 3

### [ Session Management Response Identified ](https://www.zaproxy.org/docs/alerts/10112/)



##### Informational (Medium)

### Description

The given response has been identified as containing a session management token. The 'Other Info' field contains a set of header tokens that can be used in the Header Based Session Management Method. If the request is in a context which has a Session Management Method set to "Auto-Detect" then this rule will change the session management to use the tokens identified.

* URL: https://testten1.preprod.agw.sjfisher.com/oidc/login%3Fprompt=select_account
  * Node Name: `https://testten1.preprod.agw.sjfisher.com/oidc/login (prompt)`
  * Method: `GET`
  * Parameter: `oidc_prompt`
  * Attack: ``
  * Evidence: `oidc_prompt`
  * Other Info: `cookie:oidc_prompt
cookie:oidc_state`


Instances: 1

### Solution

This is an informational alert rather than a vulnerability and so there is nothing to fix.

### Reference


* [ https://www.zaproxy.org/docs/desktop/addons/authentication-helper/session-mgmt-id/ ](https://www.zaproxy.org/docs/desktop/addons/authentication-helper/session-mgmt-id/)



#### Source ID: 3


