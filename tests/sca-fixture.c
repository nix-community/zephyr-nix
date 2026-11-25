
/*
 * tests/sca.nix appends this to samples/hello_world/src/main.c. A check
 * passes only when its tool reports these known defects. A tool that runs but
 * does not analyze the code reports nothing.
 */
int zephyr_nix_sca_fixture(int *p)
{
	int *q = 0;

	return *p + *q;
}
