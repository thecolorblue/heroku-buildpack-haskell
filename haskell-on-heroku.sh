export HALCYON_DIR='/app/.halcyon'

export BUILDPACK_TOP_DIR
BUILDPACK_TOP_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd -P )

if ! [ -d "${BUILDPACK_TOP_DIR}/lib/halcyon" ]; then
	mkdir -p "${BUILDPACK_TOP_DIR}/lib"
	if ! git clone --depth=1 --quiet 'https://github.com/mietek/halcyon.git' "${BUILDPACK_TOP_DIR}/lib/halcyon"; then
		echo '   *** ERROR: Cannot clone Halcyon' >&2
		exit 1
	fi
	rm -rf "${BUILDPACK_TOP_DIR}/lib/halcyon/.git"
fi

if ! [ -d "${BUILDPACK_TOP_DIR}/lib/halcyon/lib/bashmenot" ]; then
	mkdir -p "${BUILDPACK_TOP_DIR}/lib/halcyon/lib"
	if ! git clone --depth=1 --quiet 'https://github.com/mietek/bashmenot.git' "${BUILDPACK_TOP_DIR}/lib/halcyon/lib/bashmenot"; then
		echo '   *** ERROR: Cannot clone bashmenot' >&2
		exit 1
	fi
	rm -rf "${BUILDPACK_TOP_DIR}/lib/halcyon/lib/bashmenot/.git"
fi

source "${BUILDPACK_TOP_DIR}/lib/halcyon/halcyon.sh"
source "${BUILDPACK_TOP_DIR}/src/help.sh"


function set_config_vars () {
	local config_dir
	expect_args config_dir -- "$@"

	log 'Setting config vars'

	local ignored_pattern secret_pattern
	ignored_pattern='GIT_DIR|PATH|LIBRARY_PATH|LD_LIBRARY_PATH|LD_PRELOAD'
	secret_pattern='HALCYON_AWS_SECRET_ACCESS_KEY|DATABASE_URL|.*_POSTGRESQL_.*_URL'

	local vars
	vars=$(
		find_spaceless_recursively "${config_dir}" -maxdepth 1 |
		sort_naturally |
		filter_not_matching "^(${ignored_pattern})$"
	) || die
	if [ -z "${vars}" ]; then
		return 0
	fi

	local var
	for var in ${vars}; do
		local value
		value=$( match_exactly_one <"${config_dir}/${var}" ) || die
		if filter_matching "^(${secret_pattern})$" <<<"${var}" |
			match_exactly_one >'/dev/null'
		then
			log_indent "${var} (secret)"
		else
			log_indent "${var}=${value}"
		fi
		export "${var}=${value}" || die
	done
}


function slug_buildpack () {
	expect_vars HALCYON_DIR BUILDPACK_TOP_DIR
	expect_existing "${BUILDPACK_TOP_DIR}"

	local build_dir
	expect_args build_dir -- "$@"

	expect_no_existing "${build_dir}/.haskell-on-heroku"
	mkdir -p "${build_dir}/.haskell-on-heroku" || die
	cp -R "${BUILDPACK_TOP_DIR}/"* "${build_dir}/.haskell-on-heroku" || die

	mkdir -p "${build_dir}/.profile.d" || die
	(
		cat >"${build_dir}/.profile.d/haskell-on-heroku.sh" <<-EOF
			if ! (( ${HALCYON_INTERNAL_NO_SET_ENV:-0} )); then
				export HALCYON_INTERNAL_NO_SET_ENV=1

				export PATH="${HALCYON_DIR}/ghc/bin:\${PATH}"
				export PATH="${HALCYON_DIR}/cabal/bin:\${PATH}"
				export PATH="${HALCYON_DIR}/sandbox/bin:\${PATH}"
				export PATH="${HALCYON_DIR}/app/bin:\${PATH}"
				export PATH="/app/.haskell-on-heroku/lib/halcyon/bin:\${PATH}"
				export PATH="/app/.haskell-on-heroku/bin:\${PATH}"

				export LIBRARY_PATH="${HALCYON_DIR}/ghc/lib:\${LIBRARY_PATH:-}"
				export LD_LIBRARY_PATH="${HALCYON_DIR}/ghc/lib:\${LD_LIBRARY_PATH:-}"

				export LANG="\${LANG:-en_US.UTF-8}"
			fi
EOF
	) || die
}


function slug_app () {
	expect_vars HALCYON_DIR
	expect_existing "${HALCYON_DIR}/app"

	local build_dir
	expect_args build_dir -- "$@"

	# NOTE: ${build_dir}/.halcyon will become the HALCYON_DIR (/app/.halcyon) on a dyno.

	expect_no_existing "${build_dir}/.halcyon/app"

	mkdir -p "${build_dir}/.halcyon" || die
	cp -R "${HALCYON_DIR}/app" "${build_dir}/.halcyon" || die

	if ! [ -f "${build_dir}/Procfile" ]; then
		local app_executable
		app_executable=$( detect_app_executable "${build_dir}" ) || die
		expect_existing "${build_dir}/.halcyon/app/bin/${app_executable}"

		echo "web: ${HALCYON_DIR}/app/bin/${app_executable}" >"${build_dir}/Procfile" || die
	fi

	expect_no_existing "${build_dir}/.ghc" "${build_dir}/.cabal" "${build_dir}/.cabal-sandbox"
	rm -rf "${build_dir}/cabal.sandbox.config" "${build_dir}/dist"
}


function heroku_compile () {
	local build_dir cache_dir env_dir
	expect_args build_dir cache_dir env_dir -- "$@"
	expect_existing "${build_dir}"

	slug_buildpack "${build_dir}" || die

	export HALCYON_CACHE_DIR="${cache_dir}"
	export HALCYON_NO_BUILD=1
	set_default_vars
	set_config_vars "${env_dir}"

	if ! halcyon_deploy "${build_dir}"; then
		log
		help_deploy_failed
		log
		return 0
	fi

	log
	help_deploy_succeeded
	log

	slug_app "${build_dir}" || die
}


function heroku_build () {
	expect_existing '/app'

	set_default_vars

	if ! has_private_storage; then
		log_error 'Expected private storage'
		log
		help_configure_private_storage
		die
	fi

	halcyon_deploy '/app' || die

	log
	help_build_succeeded
}


function heroku_restore () {
	expect_existing '/app'

	export HALCYON_NO_BUILD=1
	set_default_vars

	halcyon_deploy '/app' || die

	log
	help_restore_succeeded
}
