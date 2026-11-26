### collaudatore-001
- Situazione: In Test non gira l'alpha del ramo della card ma una build beta di develop, perché la PR della card è già stata unita e il deploy è stato fatto da develop.
- Cosa fare: Non confrontare l'etichetta di versione con quella attesa del ramo: dalla build in Test (versione letta da /api/health e /assets/version.json) risali con az al commit sorgente e verifica con git merge-base --is-ancestor <HEAD del ramo> <commit della build> che contenga l'HEAD della card; se lo contiene collaudi su quei binari, scrivendo nel commento versione e commit provati e che develop include anche lavoro di altre card; ti fermi solo se l'HEAD non è contenuto.
- Perché: Quello che conta è che le correzioni da provare siano nei binari, non da quale ramo vengono: una beta di develop che contiene l'HEAD le ha, e fermarsi lì costa un giro di on-hold senza motivo, mentre una build che non lo contiene ripropone i difetti già rimandati indietro.
- Card: 11
