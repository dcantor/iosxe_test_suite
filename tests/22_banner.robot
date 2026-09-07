*** Settings ***
Documentation     The pre-login banner.
...
...               "banner login" is the one shown before the username and
...               password prompt, which is what makes it a warning rather than a
...               greeting: "banner exec" appears only after a successful login,
...               by which point it has told an unauthorised visitor nothing they
...               needed to hear beforehand.
...
...               So the assertions that matter are not that the text is in the
...               configuration but that it reaches someone who has not logged in.
...               IOS delivers it as an SSH userauth banner, so the tests capture
...               it from a deliberately failed authentication -- no credentials
...               involved, and a successful login would prove the weaker thing.
Resource          ../resources/c8000v.resource
Library           ${CURDIR}/../tools/banner_keywords.py
Library           String
Suite Setup       Open All Routers
Suite Teardown    Close All Connections

*** Test Cases ***
Every Router Has A Login Banner Configured
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show running-config | include ^banner
        Should Contain    ${out}    banner login    ${r} has no login banner
    END

The Banner Is Presented Before Authentication
    [Documentation]    Captured from a login that is refused, so the banner
    ...                demonstrably reaches an unauthenticated client.
    FOR    ${r}    IN    @{ROUTERS}
        ${banner}=    Pre Login Banner From    ${r}
        Should Not Be Empty    ${banner}
        ...    ${r} sent no banner to an unauthenticated client
    END

The Presented Banner Matches The Source File Exactly
    [Documentation]    Line for line, not a substring match: a device carrying a
    ...                stale or truncated copy should fail rather than pass on
    ...                one memorable phrase still being present.
    FOR    ${r}    IN    @{ROUTERS}
        ${banner}=    Pre Login Banner From    ${r}
        ${lines}=    Banner Should Match File    ${banner}
        Log    ${r}: ${lines} banner lines match ${BANNER_FILE}    console=${TRUE}
    END

The Banner States The Warning It Exists To Give
    [Documentation]    A banner that does not actually warn is decoration. These
    ...                are the elements that make it one: restricted access, a
    ...                statement of monitoring, and consent following from use.
    ${banner}=    Pre Login Banner From    R1
    FOR    ${phrase}    IN    AUTHORISED ACCESS ONLY    restricted to authorised personnel
    ...    monitored, logged and audited    constitutes consent
        Should Contain    ${banner}    ${phrase}
        ...    the banner does not state: ${phrase}
    END

The Banner Discloses Nothing About The Platform
    [Documentation]    An unauthenticated visitor should learn that they are not
    ...                welcome, and nothing else. A banner naming the vendor,
    ...                model, software or hostname helps whoever should not be
    ...                there more than it helps anyone who should.
    FOR    ${r}    IN    @{ROUTERS}
        ${banner}=    Pre Login Banner From    ${r}
        Banner Should Not Disclose    ${banner}    cisco    ios    c8000v
        ...    ${${r}_NAME}    ${${r}_OOB_IP}    version
    END

The Banner Survives A Configuration Save
    [Documentation]    Guards the case where a banner is applied to the running
    ...                configuration and never written -- present until the next
    ...                reload, and absent exactly when it would be needed.
    FOR    ${r}    IN    @{ROUTERS}
        ${out}=    Run On    ${r}    show startup-config | include ^banner
        Should Contain    ${out}    banner login
        ...    ${r}'s banner is not in the startup configuration and would be lost on reload
    END
