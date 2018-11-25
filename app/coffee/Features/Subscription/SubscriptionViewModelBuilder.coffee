Settings = require('settings-sharelatex')
RecurlyWrapper = require("./RecurlyWrapper")
PlansLocator = require("./PlansLocator")
SubscriptionFormatters = require("./SubscriptionFormatters")
LimitationsManager = require("./LimitationsManager")
SubscriptionLocator = require("./SubscriptionLocator")
V1SubscriptionManager = require("./V1SubscriptionManager")
logger = require('logger-sharelatex')
_ = require("underscore")


buildBillingDetails = (recurlySubscription) ->
	hostedLoginToken = recurlySubscription?.account?.hosted_login_token
	recurlySubdomain = Settings?.apis?.recurly?.subdomain
	if hostedLoginToken? && recurlySubdomain?
		return [
			"https://",
			recurlySubdomain,
			".recurly.com/account/billing_info/edit?ht=",
			hostedLoginToken
		].join("")

module.exports =
	buildUsersSubscriptionViewModel: (user, callback = (error, subscription, memberSubscriptions, billingDetailsLink) ->) ->
		SubscriptionLocator.getUsersSubscription user, (err, subscription) ->
			return callback(err) if err?

			SubscriptionLocator.getMemberSubscriptions user, (err, memberSubscriptions = []) ->
				return callback(err) if err?

				V1SubscriptionManager.getSubscriptionsFromV1 user._id, (err, v1Subscriptions) ->
					return callback(err) if err?

					if subscription?
						return callback(error) if error?

						plan = PlansLocator.findLocalPlanInSettings(subscription.planCode)

						if !plan?
							err = new Error("No plan found for planCode '#{subscription.planCode}'")
							logger.error {user_id: user._id, err}, "error getting subscription plan for user"
							return callback(err)

						RecurlyWrapper.getSubscription subscription.recurlySubscription_id, includeAccount: true, (err, recurlySubscription)->
							tax = recurlySubscription?.tax_in_cents || 0

							callback null, {
								admin_id:subscription.admin_id
								name: plan.name
								nextPaymentDueAt: SubscriptionFormatters.formatDate(recurlySubscription?.current_period_ends_at)
								state: recurlySubscription?.state
								price: SubscriptionFormatters.formatPrice (recurlySubscription?.unit_amount_in_cents + tax), recurlySubscription?.currency
								planCode: subscription.planCode
								currency:recurlySubscription?.currency
								taxRate:parseFloat(recurlySubscription?.tax_rate?._)
								groupPlan: subscription.groupPlan
								trial_ends_at:recurlySubscription?.trial_ends_at
							}, memberSubscriptions, buildBillingDetails(recurlySubscription), v1Subscriptions

					else
						callback null, null, memberSubscriptions, null, v1Subscriptions

	buildViewModel : ->
		plans = Settings.plans

		allPlans = {}
		plans.forEach (plan)->
			allPlans[plan.planCode] = plan

		result =
			allPlans: allPlans


		result.personalAccount = _.find plans, (plan)->
			plan.planCode == "personal"

		result.studentAccounts = _.filter plans, (plan)->
			plan.planCode.indexOf("student") != -1

		result.groupMonthlyPlans = _.filter plans, (plan)->
			plan.groupPlan and !plan.annual

		result.groupAnnualPlans = _.filter plans, (plan)->
			plan.groupPlan and plan.annual

		result.individualMonthlyPlans = _.filter plans, (plan)->
			!plan.groupPlan and !plan.annual and plan.planCode != "personal" and plan.planCode.indexOf("student") == -1

		result.individualAnnualPlans = _.filter plans, (plan)->
			!plan.groupPlan and plan.annual and plan.planCode.indexOf("student") == -1

		return result
