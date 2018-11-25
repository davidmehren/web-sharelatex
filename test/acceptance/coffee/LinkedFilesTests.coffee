async = require "async"
expect = require("chai").expect
_ = require 'underscore'
mkdirp = require "mkdirp"

Settings = require "settings-sharelatex"
MockFileStoreApi = require './helpers/MockFileStoreApi'
request = require "./helpers/request"
User = require "./helpers/User"


express = require("express")
LinkedUrlProxy = express()
LinkedUrlProxy.get "/", (req, res, next) =>
	if req.query.url == 'http://example.com/foo'
		res.send('foo foo foo')
	else if req.query.url == 'http://example.com/bar'
		res.send('bar bar bar')
	else
		res.sendStatus(404)

describe "LinkedFiles", ->
	before (done) ->
		LinkedUrlProxy.listen 6543, (error) =>
			return done(error) if error?
			@owner = new User()
			@owner.login ->
				mkdirp Settings.path.dumpFolder, done

	describe "creating a project linked file", ->
		before (done) ->
			@source_doc_name = 'test.txt'
			async.series [
				(cb) =>
					@owner.createProject 'plf-test-one', {template: 'blank'}, (error, project_id) =>
						@project_one_id = project_id
						cb(error)
				(cb) =>
					@owner.getProject @project_one_id, (error, project) =>
						@project_one = project
						@project_one_root_folder_id = project.rootFolder[0]._id.toString()
						cb(error)
				(cb) =>
					@owner.createProject 'plf-test-two', {template: 'blank'}, (error, project_id) =>
						@project_two_id = project_id
						cb(error)
				(cb) =>
					@owner.getProject @project_two_id, (error, project) =>
						@project_two = project
						@project_two_root_folder_id = project.rootFolder[0]._id.toString()
						cb(error)
				(cb) =>
					@owner.createDocInProject @project_two_id,
						@project_two_root_folder_id,
						@source_doc_name,
						(error, doc_id) =>
							@source_doc_id = doc_id
							cb(error)
			], done

		it 'should import a file from the source project', (done) ->
			@owner.request.post {
				url: "/project/#{@project_one_id}/linked_file",
				json:
					name: 'test-link.txt',
					parent_folder_id: @project_one_root_folder_id,
					provider: 'project_file',
					data:
						source_project_id: @project_two_id,
						source_entity_path: "/#{@source_doc_name}",
						source_project_display_name: "Project Two"
			}, (error, response, body) =>
				new_file_id = body.new_file_id
				@existing_file_id = new_file_id
				expect(new_file_id).to.exist
				@owner.getProject @project_one_id, (error, project) =>
					return done(error) if error?
					firstFile = project.rootFolder[0].fileRefs[0]
					expect(firstFile._id.toString()).to.equal(new_file_id.toString())
					expect(firstFile.name).to.equal('test-link.txt')
					done()

		it 'should refresh the file', (done) ->
			@owner.request.post {
				url: "/project/#{@project_one_id}/linked_file",
				json:
					name: 'test-link.txt',
					parent_folder_id: @project_one_root_folder_id,
					provider: 'project_file',
					data:
						source_project_id: @project_two_id,
						source_entity_path: "/#{@source_doc_name}",
						source_project_display_name: "Project Two"
			}, (error, response, body) =>
				new_file_id = body.new_file_id
				expect(new_file_id).to.exist
				expect(new_file_id).to.not.equal @existing_file_id
				@owner.getProject @project_one_id, (error, project) =>
					return done(error) if error?
					firstFile = project.rootFolder[0].fileRefs[0]
					expect(firstFile._id.toString()).to.equal(new_file_id.toString())
					expect(firstFile.name).to.equal('test-link.txt')
					done()

	describe "creating a URL based linked file", ->
		before (done) ->
			@owner.createProject "url-linked-files-project", {template: "blank"}, (error, project_id) =>
				throw error if error?
				@project_id = project_id
				@owner.getProject project_id, (error, project) =>
					throw error if error?
					@project = project
					@root_folder_id = project.rootFolder[0]._id.toString()
					done()

		it "should download the URL and create a file with the contents and linkedFileData", (done) ->
			@owner.request.post {
				url: "/project/#{@project_id}/linked_file",
				json:
					provider: 'url'
					data: {
						url: 'http://example.com/foo'
					}
					parent_folder_id: @root_folder_id
					name: 'url-test-file-1'
			}, (error, response, body) =>
				throw error if error?
				expect(response.statusCode).to.equal 200
				@owner.getProject @project_id, (error, project) =>
					throw error if error?
					file = project.rootFolder[0].fileRefs[0]
					expect(file.linkedFileData).to.deep.equal({
						provider: 'url'
						url: 'http://example.com/foo'
					})
					@owner.request.get "/project/#{@project_id}/file/#{file._id}", (error, response, body) ->
						throw error if error?
						expect(response.statusCode).to.equal 200
						expect(body).to.equal "foo foo foo"
						done()

		it "should replace and update a URL based linked file", (done) ->
			@owner.request.post {
				url: "/project/#{@project_id}/linked_file",
				json:
					provider: 'url'
					data: {
						url: 'http://example.com/foo'
					}
					parent_folder_id: @root_folder_id
					name: 'url-test-file-2'
			}, (error, response, body) =>
				throw error if error?
				expect(response.statusCode).to.equal 200
				@owner.request.post {
					url: "/project/#{@project_id}/linked_file",
					json:
						provider: 'url'
						data: {
							url: 'http://example.com/bar'
						}
						parent_folder_id: @root_folder_id
						name: 'url-test-file-2'
				}, (error, response, body) =>
					throw error if error?
					expect(response.statusCode).to.equal 200
					@owner.getProject @project_id, (error, project) =>
						throw error if error?
						file = project.rootFolder[0].fileRefs[1]
						expect(file.linkedFileData).to.deep.equal({
							provider: 'url'
							url: 'http://example.com/bar'
						})
						@owner.request.get "/project/#{@project_id}/file/#{file._id}", (error, response, body) ->
							throw error if error?
							expect(response.statusCode).to.equal 200
							expect(body).to.equal "bar bar bar"
							done()

		it "should return an error if the URL does not succeed", (done) ->
			@owner.request.post {
				url: "/project/#{@project_id}/linked_file",
				json:
					provider: 'url'
					data: {
						url: 'http://example.com/does-not-exist'
					}
					parent_folder_id: @root_folder_id
					name: 'url-test-file-3'
			}, (error, response, body) =>
				throw error if error?
				expect(response.statusCode).to.equal 422 # unprocessable
				expect(body).to.equal(
					"Your URL could not be reached (404 status code). Please check it and try again."
				)
				done()

		it "should return an error if the URL is invalid", (done) ->
			@owner.request.post {
				url: "/project/#{@project_id}/linked_file",
				json:
					provider: 'url'
					data: {
						url: "!^$%"
					}
					parent_folder_id: @root_folder_id
					name: 'url-test-file-4'
			}, (error, response, body) =>
				throw error if error?
				expect(response.statusCode).to.equal 422 # unprocessable
				expect(body).to.equal(
					"Your URL is not valid. Please check it and try again."
				)
				done()

		it "should return an error if the URL uses a non-http protocol", (done) ->
			@owner.request.post {
				url: "/project/#{@project_id}/linked_file",
				json:
					provider: 'url'
					data: {
						url: "ftp://localhost"
					}
					parent_folder_id: @root_folder_id
					name: 'url-test-file-5'
			}, (error, response, body) =>
				throw error if error?
				expect(response.statusCode).to.equal 422 # unprocessable
				expect(body).to.equal(
					"Your URL is not valid. Please check it and try again."
				)
				done()

		it "should accept a URL withuot a leading http://, and add it", (done) ->
			@owner.request.post {
				url: "/project/#{@project_id}/linked_file",
				json:
					provider: 'url'
					data: {
						url: 'example.com/foo'
					}
					parent_folder_id: @root_folder_id
					name: 'url-test-file-6'
			}, (error, response, body) =>
				throw error if error?
				expect(response.statusCode).to.equal 200
				@owner.getProject @project_id, (error, project) =>
					throw error if error?
					file = _.find project.rootFolder[0].fileRefs, (file) ->
						file.name == 'url-test-file-6'
					expect(file.linkedFileData).to.deep.equal({
						provider: 'url'
						url: 'http://example.com/foo'
					})
					@owner.request.get "/project/#{@project_id}/file/#{file._id}", (error, response, body) ->
						throw error if error?
						expect(response.statusCode).to.equal 200
						expect(body).to.equal "foo foo foo"
						done()

		# TODO: Add test for asking for host that return ENOTFOUND
		# (This will probably end up handled by the proxy)