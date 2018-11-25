define [
	"base"
	"libs/recurly-4.8.5"
], (App, recurly) ->

	App.factory "MultiCurrencyPricing", () ->

		currencyCode = window.recomendedCurrency

		return {
			currencyCode:currencyCode

			plans:
				USD:
					symbol: "$"
					student:
						monthly: "$8"
						annual: "$80"
					collaborator:
						monthly: "$15"
						annual: "$180"
					professional:
						monthly: "$30"
						annual: "$360"

				EUR:
					symbol: "€"
					student:
						monthly: "€7"
						annual: "€70"
					collaborator:
						monthly: "€14"
						annual: "€168"
					professional:
						monthly: "€28"
						annual: "€336"

				GBP:
					symbol: "£"
					student:
						monthly: "£6"
						annual: "£60"
					collaborator:
						monthly: "£12"
						annual: "£144"
					professional:
						monthly: "£24"
						annual: "£288"

				SEK:
					symbol: "kr"
					student:
						monthly: "60 kr"
						annual: "600 kr"
					collaborator:
						monthly: "110 kr"
						annual: "1320 kr"
					professional:
						monthly: "220 kr"
						annual: "2640 kr"
				CAD:
					symbol: "$"
					student:
						monthly: "$9"
						annual: "$90"
					collaborator:
						monthly: "$17"
						annual: "$204"
					professional:
						monthly: "$34"
						annual: "$408"

				NOK:
					symbol: "kr"
					student:
						monthly: "60 kr"
						annual: "600 kr"
					collaborator:
						monthly: "110 kr"
						annual: "1320 kr"
					professional:
						monthly: "220 kr"
						annual: "2640 kr"

				DKK:
					symbol: "kr"
					student:
						monthly: "50 kr"
						annual: "500 kr"
					collaborator:
						monthly: "90 kr"
						annual: "1080 kr"
					professional:
						monthly: "180 kr"
						annual: "2160 kr"

				AUD:
					symbol: "$"
					student:
						monthly: "$10"
						annual: "$100"
					collaborator:
						monthly: "$18"
						annual: "$216"
					professional:
						monthly: "$35"
						annual: "$420"

				NZD:
					symbol: "$"
					student:
						monthly: "$10"
						annual: "$100"
					collaborator:
						monthly: "$18"
						annual: "$216"
					professional:
						monthly: "$35"
						annual: "$420"

				CHF:
					symbol: "Fr"
					student:
						monthly: "Fr 8"
						annual: "Fr 80"
					collaborator:
						monthly: "Fr 15"
						annual: "Fr 180"
					professional:
						monthly: "Fr 30"
						annual: "Fr 360"

				SGD:
					symbol: "$"
					student:
						monthly: "$12"
						annual: "$120"
					collaborator:
						monthly: "$20"
						annual: "$240"
					professional:
						monthly: "$40"
						annual: "$480"

		}


	App.controller "PlansController", ($scope, $modal, event_tracking, abTestManager, MultiCurrencyPricing, $http, sixpack, $filter) ->

		$scope.showPlans = false
		$scope.shouldABTestPlans = window.shouldABTestPlans

		if $scope.shouldABTestPlans
			sixpack.participate 'plans-details', ['default', 'more-details'], (chosenVariation, rawResponse)->
				$scope.plansVariant = chosenVariation

		$scope.showPlans = true

		$scope.plans = MultiCurrencyPricing.plans

		$scope.currencyCode = MultiCurrencyPricing.currencyCode

		$scope.trial_len = 7

		$scope.planQueryString = '_free_trial_7_days'

		$scope.ui =
			view: "monthly"

		$scope.changeCurreny = (e, newCurrency)->
			e.preventDefault()
			$scope.currencyCode = newCurrency

		# because ternary logic in angular bindings is hard
		$scope.getCollaboratorPlanCode = () ->
			view = $scope.ui.view
			if view == "annual"
				return "collaborator-annual"
			else
				return "collaborator#{$scope.planQueryString}"

		$scope.signUpNowClicked = (plan, location)->
			if $scope.ui.view == "annual"
				plan = "#{plan}_annual"
			plan = eventLabel(plan, location)
			event_tracking.sendMB 'plans-page-start-trial', {plan}
			event_tracking.send 'subscription-funnel', 'sign_up_now_button', plan
			if $scope.shouldABTestPlans
				sixpack.convert 'plans-details'

		$scope.switchToMonthly = (e, location) ->
			uiView = 'monthly'
			switchEvent(e, uiView + '-prices', location)
			$scope.ui.view = uiView

		$scope.switchToStudent = (e, location) ->
			uiView = 'student'
			switchEvent(e, uiView + '-prices', location)
			$scope.ui.view = uiView

		$scope.switchToAnnual = (e, location) ->
			uiView = 'annual'
			switchEvent(e, uiView + '-prices', location)
			$scope.ui.view = uiView

		$scope.openGroupPlanModal = () ->
			$modal.open {
				templateUrl: "groupPlanModalTemplate"
			}
			event_tracking.send 'subscription-funnel', 'plans-page', 'group-inquiry-potential'

		eventLabel = (label, location) ->
			if location && $scope.plansVariant != 'default'
				label = label + '-' + location
			if $scope.plansVariant != 'default'
				label += '-exp-' + $scope.plansVariant
			label

		switchEvent = (e, label, location) ->
			e.preventDefault()
			gaLabel = eventLabel(label, location)
			event_tracking.send 'subscription-funnel', 'plans-page', gaLabel

