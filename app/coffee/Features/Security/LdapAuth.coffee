settings = require('settings-sharelatex')
logger = require('logger-sharelatex')
ldap = require('ldapjs')

module.exports =
  ldapAuth: (body, callback) ->
    if (!settings.ldap)
      callback null, true
    else
      # Create LDAP client to connect to the LDAP Server
      lclient = ldap.createClient({ url: settings.ldap.server.host })

      # Settings bind the client to the LDAP server
      dnObjFilter = settings.ldap.server.bindDN
      dn = dnObjFilter
      filter = settings.ldap.server.searchFilter.replace('{{username}}', eval("body." + settings.ldap.usernameField))
      opts = { filter: filter, scope: 'sub' }

      if !settings.ldap.anonymous
        logger.log dn:dn, 'ldap bind'
        lclient.bind settings.ldap.server.bindDN, settings.ldap.server.bindCredentials, (err) ->
          logger.log opts:opts, 'ldap bind success, now ldap search'
          lclient.search settings.ldap.server.searchBase, opts, (err, res) ->
            res.on 'searchEntry', (entry) ->
              logger.log opts:opts, "ldap search success"
              body.email = entry.object[settings.ldap.emailAtt].toLowerCase()
              body.password = entry.object['userPassword']
              callback err, err == null
            res.on 'error', (err) ->
              logger.log err:err, "ldap search error"
              callback err, err == null
      else
        logger.log opts:opts, "ldap search"
        lclient.search settings.ldap.server.searchBase, opts, (err, res) ->
          res.on 'searchEntry', (entry) ->
            dn = entry.object['dn']
            logger.log dn:dn, "ldap search success, now ldap bind"
            lclient.bind dn, eval("body." + settings.ldap.passwordField), (err) ->
              body.email = entry.object[settings.ldap.emailAtt].toLowerCase()
              body.password = entry.object['userPassword']
              callback err, err == null
          res.on 'error', (err) ->
            logger.log err:err, 'ldap search error'
            callback err, err == null
