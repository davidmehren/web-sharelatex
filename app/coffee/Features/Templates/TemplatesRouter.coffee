AuthenticationController = require('../Authentication/AuthenticationController')
TemplatesController = require("./TemplatesController")
TemplatesMiddlewear = require('./TemplatesMiddlewear')

module.exports = 
	apply: (app)->

		app.get '/project/new/template/:Template_version_id', TemplatesMiddlewear.saveTemplateDataInSession, AuthenticationController.requireLogin(), TemplatesController.getV1Template

		app.post '/project/new/template', AuthenticationController.requireLogin(), TemplatesController.createProjectFromV1Template
