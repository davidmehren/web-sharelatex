logger = require("logger-sharelatex")
User = require('../../models/User').User

module.exports =
	updateFeatures: (user_id, features, callback = (err, features)->)->
		conditions = _id:user_id
		update = {}
		logger.log user_id:user_id, features:features, "updating users features"
		update["features.#{key}"] = value for key, value of features
		User.update conditions, update, (err)->
			callback err, features

