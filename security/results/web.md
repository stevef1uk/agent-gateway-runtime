# ZAP Scanning Report

ZAP by [Checkmarx](https://checkmarx.com/).


## Summary of Alerts

| Risk Level | Number of Alerts |
| --- | --- |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| Informational | 5 |




## Insights

| Level | Reason | Site | Description | Statistic |
| --- | --- | --- | --- | --- |
| Info | Informational | http://localhost:8083 | Percentage of responses with status code 2xx | 41 % |
| Info | Informational | http://localhost:8083 | Percentage of responses with status code 3xx | 41 % |
| Info | Informational | http://localhost:8083 | Percentage of responses with status code 4xx | 16 % |
| Info | Informational | http://localhost:8083 | Percentage of endpoints with content type text/css | 10 % |
| Info | Informational | http://localhost:8083 | Percentage of endpoints with content type text/html | 60 % |
| Info | Informational | http://localhost:8083 | Percentage of endpoints with content type text/javascript | 10 % |
| Info | Informational | http://localhost:8083 | Percentage of endpoints with content type text/plain | 20 % |
| Info | Informational | http://localhost:8083 | Percentage of endpoints with method GET | 100 % |
| Info | Informational | http://localhost:8083 | Count of total endpoints | 10    |







## Alerts

| Name | Risk Level | Number of Instances |
| --- | --- | --- |
| Information Disclosure - Suspicious Comments | Informational | 2 |
| Non-Storable Content | Informational | 5 |
| Session Management Response Identified | Informational | 2 |
| Storable and Cacheable Content | Informational | 2 |
| Storable but Non-Cacheable Content | Informational | 4 |




## Alert Detail



### [ Information Disclosure - Suspicious Comments ](https://www.zaproxy.org/docs/alerts/10027/)



##### Informational (Medium)

### Description

The response appears to contain suspicious comments which may help an attacker.

* URL: http://localhost:8083/assets/index.js
  * Node Name: `http://localhost:8083/assets/index.js`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `// Identity comes from the server-side con`
  * Other Info: `The following pattern was used: \bFROM\b and was detected 3 times, the first in likely comment: "// Identity comes from the server-side console session: when signed in the", see evidence field for the suspicious comment/snippet.`
* URL: http://localhost:8083/assets/index.js
  * Node Name: `http://localhost:8083/assets/index.js`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `// a user name is sent only w`
  * Other Info: `The following pattern was used: \bUSER\b and was detected 2 times, the first in likely comment: "// a user name is sent only when there is no verified session (dev mode).", see evidence field for the suspicious comment/snippet.`


Instances: 2

### Solution

Remove all comments that return information that may help an attacker and fix any underlying problems they refer to.

### Reference



#### CWE Id: [ 615 ](https://cwe.mitre.org/data/definitions/615.html)


#### WASC Id: 13

#### Source ID: 3

### [ Non-Storable Content ](https://www.zaproxy.org/docs/alerts/10049/)



##### Informational (Medium)

### Description

The response contents are not storable by caching components such as proxy servers. If the response does not contain sensitive, personal or user-specific information, it may benefit from being stored and cached, to improve performance.

* URL: http://localhost:8083/oidc/idp/dex/auth%3Fclient_id=agent-gateway&connector_id=mock&redirect_uri=http%253A%252F%252Flocalhost%253A8083%252Foidc%252Fcallback&response_type=code&scope=openid+email+profile&state=Eiv8aZVPElaEcXRb8BriNQ
  * Node Name: `http://localhost:8083/oidc/idp/dex/auth (client_id,connector_id,redirect_uri,response_type,scope,state)`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `302`
  * Other Info: ``
* URL: http://localhost:8083/oidc/idp/dex/auth%3Fhmac=mq0GPnBV-BEliLXGsAq0Qd57gNcUgTrW18T3PgIzPA0&req=ufjqcyevrxm37bq2q5hhshffi
  * Node Name: `http://localhost:8083/oidc/idp/dex/auth (hmac,req)`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `303`
  * Other Info: ``
* URL: http://localhost:8083/oidc/idp/dex/auth/mock%3Fclient_id=agent-gateway&redirect_uri=http%253A%252F%252Flocalhost%253A8083%252Foidc%252Fcallback&response_type=code&scope=openid+email+profile&state=Eiv8aZVPElaEcXRb8BriNQ
  * Node Name: `http://localhost:8083/oidc/idp/dex/auth/mock (client_id,redirect_uri,response_type,scope,state)`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `302`
  * Other Info: ``
* URL: http://localhost:8083/oidc/idp/dex/callback%3Fstate=ufjqcyevrxm37bq2q5hhshffi
  * Node Name: `http://localhost:8083/oidc/idp/dex/callback (state)`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `303`
  * Other Info: ``
* URL: http://localhost:8083/oidc/login
  * Node Name: `http://localhost:8083/oidc/login`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `302`
  * Other Info: ``


Instances: 5

### Solution

The content may be marked as storable by ensuring that the following conditions are satisfied:
The request method must be understood by the cache and defined as being cacheable ("GET", "HEAD", and "POST" are currently defined as cacheable)
The response status code must be understood by the cache (one of the 1XX, 2XX, 3XX, 4XX, or 5XX response classes are generally understood)
The "no-store" cache directive must not appear in the request or response header fields
For caching by "shared" caches such as "proxy" caches, the "private" response directive must not appear in the response
For caching by "shared" caches such as "proxy" caches, the "Authorization" header field must not appear in the request, unless the response explicitly allows it (using one of the "must-revalidate", "public", or "s-maxage" Cache-Control response directives)
In addition to the conditions above, at least one of the following conditions must also be satisfied by the response:
It must contain an "Expires" header field
It must contain a "max-age" response directive
For "shared" caches such as "proxy" caches, it must contain a "s-maxage" response directive
It must contain a "Cache Control Extension" that allows it to be cached
It must have a status code that is defined as cacheable by default (200, 203, 204, 206, 300, 301, 404, 405, 410, 414, 501).

### Reference


* [ https://datatracker.ietf.org/doc/html/rfc7234 ](https://datatracker.ietf.org/doc/html/rfc7234)
* [ https://datatracker.ietf.org/doc/html/rfc7231 ](https://datatracker.ietf.org/doc/html/rfc7231)
* [ https://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html ](https://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html)


#### CWE Id: [ 524 ](https://cwe.mitre.org/data/definitions/524.html)


#### WASC Id: 13

#### Source ID: 3

### [ Session Management Response Identified ](https://www.zaproxy.org/docs/alerts/10112/)



##### Informational (Medium)

### Description

The given response has been identified as containing a session management token. The 'Other Info' field contains a set of header tokens that can be used in the Header Based Session Management Method. If the request is in a context which has a Session Management Method set to "Auto-Detect" then this rule will change the session management to use the tokens identified.

* URL: http://localhost:8083/oidc/login
  * Node Name: `http://localhost:8083/oidc/login`
  * Method: `GET`
  * Parameter: `oidc_state`
  * Attack: ``
  * Evidence: `oidc_state`
  * Other Info: `cookie:oidc_state`
* URL: http://localhost:8083/oidc/idp/dex/auth/mock%3Fclient_id=agent-gateway&redirect_uri=http%253A%252F%252Flocalhost%253A8083%252Foidc%252Fcallback&response_type=code&scope=openid+email+profile&state=Eiv8aZVPElaEcXRb8BriNQ
  * Node Name: `http://localhost:8083/oidc/idp/dex/auth/mock (client_id,redirect_uri,response_type,scope,state)`
  * Method: `GET`
  * Parameter: `state`
  * Attack: ``
  * Evidence: `state`
  * Other Info: `url:state`


Instances: 2

### Solution

This is an informational alert rather than a vulnerability and so there is nothing to fix.

### Reference


* [ https://www.zaproxy.org/docs/desktop/addons/authentication-helper/session-mgmt-id/ ](https://www.zaproxy.org/docs/desktop/addons/authentication-helper/session-mgmt-id/)



#### Source ID: 3

### [ Storable and Cacheable Content ](https://www.zaproxy.org/docs/alerts/10049/)



##### Informational (Medium)

### Description

The response contents are storable by caching components such as proxy servers, and may be retrieved directly from the cache, rather than from the origin server by the caching servers, in response to similar requests from other users. If the response data is sensitive, personal or user-specific, this may result in sensitive information being leaked. In some cases, this may even result in a user gaining complete control of the session of another user, depending on the configuration of the caching components in use in their environment. This is primarily an issue where "shared" caching servers such as "proxy" caches are configured on the local network. This configuration is typically found in corporate or educational environments, for instance.

* URL: http://localhost:8083/robots.txt
  * Node Name: `http://localhost:8083/robots.txt`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: ``
  * Other Info: `In the absence of an explicitly specified caching lifetime directive in the response, a liberal lifetime heuristic of 1 year was assumed. This is permitted by rfc7234.`
* URL: http://localhost:8083/sitemap.xml
  * Node Name: `http://localhost:8083/sitemap.xml`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: ``
  * Other Info: `In the absence of an explicitly specified caching lifetime directive in the response, a liberal lifetime heuristic of 1 year was assumed. This is permitted by rfc7234.`


Instances: 2

### Solution

Validate that the response does not contain sensitive, personal or user-specific information. If it does, consider the use of the following HTTP response headers, to limit, or prevent the content being stored and retrieved from the cache by another user:
Cache-Control: no-cache, no-store, must-revalidate, private
Pragma: no-cache
Expires: 0
This configuration directs both HTTP 1.0 and HTTP 1.1 compliant caching servers to not store the response, and to not retrieve the response (without validation) from the cache, in response to a similar request.

### Reference


* [ https://datatracker.ietf.org/doc/html/rfc7234 ](https://datatracker.ietf.org/doc/html/rfc7234)
* [ https://datatracker.ietf.org/doc/html/rfc7231 ](https://datatracker.ietf.org/doc/html/rfc7231)
* [ https://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html ](https://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html)


#### CWE Id: [ 524 ](https://cwe.mitre.org/data/definitions/524.html)


#### WASC Id: 13

#### Source ID: 3

### [ Storable but Non-Cacheable Content ](https://www.zaproxy.org/docs/alerts/10049/)



##### Informational (Medium)

### Description

The response contents are storable by caching components such as proxy servers, but will not be retrieved directly from the cache, without validating the request upstream, in response to similar requests from other users.

* URL: http://localhost:8083
  * Node Name: `http://localhost:8083`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `no-cache`
  * Other Info: ``
* URL: http://localhost:8083/
  * Node Name: `http://localhost:8083/`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `no-cache`
  * Other Info: ``
* URL: http://localhost:8083/assets/index.css
  * Node Name: `http://localhost:8083/assets/index.css`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `no-cache`
  * Other Info: ``
* URL: http://localhost:8083/assets/index.js
  * Node Name: `http://localhost:8083/assets/index.js`
  * Method: `GET`
  * Parameter: ``
  * Attack: ``
  * Evidence: `no-cache`
  * Other Info: ``


Instances: 4

### Solution



### Reference


* [ https://datatracker.ietf.org/doc/html/rfc7234 ](https://datatracker.ietf.org/doc/html/rfc7234)
* [ https://datatracker.ietf.org/doc/html/rfc7231 ](https://datatracker.ietf.org/doc/html/rfc7231)
* [ https://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html ](https://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html)


#### CWE Id: [ 524 ](https://cwe.mitre.org/data/definitions/524.html)


#### WASC Id: 13

#### Source ID: 3


