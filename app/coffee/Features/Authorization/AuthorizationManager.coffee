CollaboratorsHandler = require("../Collaborators/CollaboratorsHandler")
ProjectGetter = require('../Project/ProjectGetter')
User = require("../../models/User").User
PrivilegeLevels = require("./PrivilegeLevels")
PublicAccessLevels = require("./PublicAccessLevels")
Errors = require("../Errors/Errors")
ObjectId = require("mongojs").ObjectId
TokenAccessHandler = require('../TokenAccess/TokenAccessHandler')


module.exports = AuthorizationManager =

	getPublicAccessLevel: (project_id, callback=(err, level)->) ->
		if !ObjectId.isValid(project_id)
			return callback(new Error("invalid project id"))
		# Note, the Project property in the DB is `publicAccesLevel`, without the second `s`
		ProjectGetter.getProject project_id, publicAccesLevel: 1, (error, project) ->
			return callback(error) if error?
			if !project?
				return callback new Errors.NotFoundError("no project found with id #{project_id}")
			callback null, project.publicAccesLevel

	# Get the privilege level that the user has for the project
	# Returns:
	#	* privilegeLevel: "owner", "readAndWrite", of "readOnly" if the user has
	#	  access. false if the user does not have access
	#   * becausePublic: true if the access level is only because the project is public.
	getPrivilegeLevelForProject: (
		user_id, project_id, token,
		callback = (error, privilegeLevel, becausePublic) ->
	) ->
		if !user_id?
			# User is Anonymous, Try Token-based access
			AuthorizationManager.getPublicAccessLevel project_id, (err, publicAccessLevel) ->
				return callback(err) if err?
				if publicAccessLevel == PublicAccessLevels.TOKEN_BASED
					# Anonymous users can have read-only access to token-based projects,
					# while read-write access must be logged in,
					# unless the `enableAnonymousReadAndWriteSharing` setting is enabled
					TokenAccessHandler.isValidToken project_id, token, (err, isValidReadAndWrite, isValidReadOnly) ->
						return callback(err) if err?
						if isValidReadOnly
							# Grant anonymous user read-only access
							callback null, PrivilegeLevels.READ_ONLY, false
						else if (
							isValidReadAndWrite and
							TokenAccessHandler.ANONYMOUS_READ_AND_WRITE_ENABLED
						)
							# Grant anonymous user read-and-write access
							callback null, PrivilegeLevels.READ_AND_WRITE, false
						else
							# Deny anonymous access
							callback null, PrivilegeLevels.NONE, false
				else if publicAccessLevel == PublicAccessLevels.READ_ONLY
					# Legacy public read-only access for anonymous user
					callback null, PrivilegeLevels.READ_ONLY, true
				else if publicAccessLevel == PublicAccessLevels.READ_AND_WRITE
					# Legacy public read-write access for anonymous user
					callback null, PrivilegeLevels.READ_AND_WRITE, true
				else
					# Deny anonymous user access
					callback null, PrivilegeLevels.NONE, false
		else
			# User is present, get their privilege level from database
			CollaboratorsHandler.getMemberIdPrivilegeLevel user_id, project_id, (error, privilegeLevel) ->
				return callback(error) if error?
				if privilegeLevel? and privilegeLevel != PrivilegeLevels.NONE
					# The user has direct access
					callback null, privilegeLevel, false
				else
					AuthorizationManager.isUserSiteAdmin user_id, (error, isAdmin) ->
						return callback(error) if error?
						if isAdmin
							callback null, PrivilegeLevels.OWNER, false
						else
							# Legacy public-access system
							# User is present (not anonymous), but does not have direct access
							AuthorizationManager.getPublicAccessLevel project_id, (err, publicAccessLevel) ->
								return callback(err) if err?
								if publicAccessLevel == PublicAccessLevels.READ_ONLY
									callback null, PrivilegeLevels.READ_ONLY, true
								else if publicAccessLevel == PublicAccessLevels.READ_AND_WRITE
									callback null, PrivilegeLevels.READ_AND_WRITE, true
								else
									callback null, PrivilegeLevels.NONE, false

	canUserReadProject: (user_id, project_id, token, callback = (error, canRead) ->) ->
		AuthorizationManager.getPrivilegeLevelForProject user_id, project_id, token, (error, privilegeLevel) ->
			return callback(error) if error?
			return callback null, (privilegeLevel in [PrivilegeLevels.OWNER, PrivilegeLevels.READ_AND_WRITE, PrivilegeLevels.READ_ONLY])
		
	canUserWriteProjectContent: (user_id, project_id, token, callback = (error, canWriteContent) ->) ->
		AuthorizationManager.getPrivilegeLevelForProject user_id, project_id, token, (error, privilegeLevel) ->
			return callback(error) if error?
			return callback null, (privilegeLevel in [PrivilegeLevels.OWNER, PrivilegeLevels.READ_AND_WRITE])
		
	canUserWriteProjectSettings: (user_id, project_id, token, callback = (error, canWriteSettings) ->) ->
		AuthorizationManager.getPrivilegeLevelForProject user_id, project_id, token, (error, privilegeLevel, becausePublic) ->
			return callback(error) if error?
			if privilegeLevel == PrivilegeLevels.OWNER
				return callback null, true
			else if privilegeLevel == PrivilegeLevels.READ_AND_WRITE and !becausePublic
				return callback null, true
			else
				return callback null, false
	
	canUserAdminProject: (user_id, project_id, token, callback = (error, canAdmin) ->) ->
		AuthorizationManager.getPrivilegeLevelForProject user_id, project_id, token, (error, privilegeLevel) ->
			return callback(error) if error?
			return callback null, (privilegeLevel == PrivilegeLevels.OWNER)
	
	isUserSiteAdmin: (user_id, callback = (error, isAdmin) ->) ->
		if !user_id?
			return callback null, false
		User.findOne { _id: user_id }, { isAdmin: 1 }, (error, user) ->
			return callback(error) if error?
			return callback null, (user?.isAdmin == true)
